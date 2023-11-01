// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

//import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/*
 * @title DSCEngine
 * @author packagefather
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be overcollaterized. At no point should the 
 the value of all collateral <= the $ backed value of all the DSC
  
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////
    // Errors  ///
    /////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////
    // Types  ///
    /////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////////// 
    // State Vairables ///
    ////////////////////// 

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; //this means 10% bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant FEED_PRECISION = 1e8;
    
    mapping(address token => address priceFeed)private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscToMint)private s_DSCMinted;
    address[] private s_collateralTokens;


    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////// 
    // Events          ///
    ////////////////////// 
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated


    /////////////////
    // Modifiers  ///
    /////////////////
    modifier moreThanZero(uint256 amount) {
        if(amount == 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /////////////////
    // Functions  ///
    /////////////////

    constructor(address[] memory tokenAddresses, 
    address[] memory priceFeedAddress,
    address dscAddress) {

        //USD Price Feed
        if(tokenAddresses.length != priceFeedAddress.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for(uint256 i = 0; i < tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    
    ////////////////////////////////////////////
    ////////////////////////////////////////////
    // External & Public View & Pure Functions
    ////////////////////////////////////////////
    ////////////////////////////////////////////

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint 
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     *@notice follows CEI - Check Effects Interactions (we do checks first, then the effects on state
     and lastly the interractions with other contract ot functions)
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    *@notice follows CEI
    *@param amountDscToMint - the amount of decentralized stablecoin to mint
    *@notice they must have more collateral value than the min. threshold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //so we added the mintedDsc to see if it will break their health factor
        //and if it does, then we revert, if it does not then we allow
        //the idea is that we do not want people to shoot themselves in the leg
        //by allowing them to mint more DSC that will cause them liquidation

        //so technically, we check health factor by adding the newly intended DSCAmount
        //to see what it becomes
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @param amountDscToBurn: The amount of DSC to burn
     * @notice This function will burn your DSC and redeem your collateral in one trxn.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
       moreThanZero(amountCollateral)   
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }


    //In order to redeem collateral
    //1. health factor must be over 1 AFTER collateral is pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    
    }


    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
        //because paying debt wont ever break health factor, it rather improves it
    
    }

     /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150%/200% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
             revert DSCEngine__HealthFactorOk();
        }
        //we want to burn their DSC "debt" and take their collateral
        //Bad user: $140 ETH, $100 DSC
        //debtToCover = $100
        //$100 of DSC == ?? ETH ? = 0.05ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //0.05 ETH * 0.1 = 0.005. The liquidator is getting total of 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; 
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        //burn DSC of the liquidator
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        //if this process ruins the liquidators healthfactor, we shouldnt let them do it
        _revertIfHealthFactorIsBroken(msg.sender);

    }

    
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //looop through each collateral token, get the amount they have deposited,
        //and map it to the price, to get the USD value
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
     }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) public view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    ////////////////////////////////////////////
    ////////////////////////////////////////////
    // Internal & Private View & Pure Functions
    ////////////////////////////////////////////
    ////////////////////////////////////////////


function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do -
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max; //if what you owe is 0, then your health factor is like max max
        //$1000 of ETH * 50 = 50,000 / 100 = 500

        //so if we deposit $1000 collateral, 50 threshold means 50/100 = 1/2, that leaves us with $500
        //if we now do 500/100 that we borrowed, we have 5 as the health factor
        //this simply means our collateral is divided into 2, and as such we must provide 
        //200% of our debt so that when it is divided we will still have HF of 1 or higher


        //E.G 2
        //$150 of ETH * 50 = 7,500 / 100 = (75 / 100 ) < 1
        //we provide collateral of $150 and borrow $100 DSC, 
        //with our 50 threshold, it means 50/100 = 1/2 = 0.5 
        //that is $150 * 0.5 = $75
        //now $75/$100 DSC = 0.75 
        //this is lower than 1, so health factor breaks
        //so to be safe, we must privide collateral of 200% in value higher than =our borrowed DSC

        //e.g 2 
        //lets say the collateralUsdValue is $1000 and totalDscMinted is 100
        //$1000 ETH / 1000 DSC
        //1000 * 50 = 50,000 / 100 = (500 / 100) > 1

        //
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    
    /**
     * 
     * @dev Low-level internal function, do not call unless the function calling
     * it is checking for health factor being broken
     */
      function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }
    /*
     * 
     * @Notice this was a bit modified to not actually burn, so to test that price is not set to 0
     * there by not making health factor go to 0
     * with this _burn2 the health factor is actually improved
     * 
     * @Notice: This function should be deleted for production code
     */
    // function _burnDsc2(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) external {
    //     s_DSCMinted[onBehalfOf] -= amountDscToBurn;

    //     bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
    //     // This conditional is hypothetically unreachable
    //     if (!success) {
    //         revert DSCEngine__TransferFailed();
    //     }
    //     //i_dsc.burn(amountDscToBurn); //if i dont do this, the price wont be set to 0
    // }

    
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }


    //Returns how close to liquidation a user is
    //if a user is goes below 1, then they can get liquidated
    function _healthFactor(address user) private view returns (uint256) {
        //total dsc minted
        //total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        //(collateralValueInUsd / totalDscMinted) e.g 150 collateral / 100 dsc = 1.5 
        //but decimals doesnt work here so it would be 1
        //so we need to find a way to get the value with precision 
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }


    function _revertIfHealthFactorIsBroken(address user) internal view {
       //1. Check helath factor (do they have enough collateral)
       //2. Revert if they do not have 
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        //we should test this line for when liquidator tries to pay more than the user owes, 
        //in other words the collateral is not enough to pay the liquidator + bonus
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * 
     * @Notice this was deuplicated so we can make this low-level call in the test to see the data changes without
     * changing the catual function to external. 
     * 
     * @Notice: This function should be deleted for production code
     */
    // function _redeemCollateral2(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
    //     external
    // {
    //     s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
    //     emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        
    //     bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
    //     if (!success) {
    //         revert DSCEngine__TransferFailed();
    //     }
    // }

}