// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";



contract DSCEngineTest is Test {

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated



    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;


    address public Alice = makeAddr("Alice");
    address public Liquidator = makeAddr("Liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant DSC_AMOUNT_TO_MINT = 50 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(Alice, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }



    //////////////////
    // Price Tests //
    //////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100e18; //$100 but in 18 decimal places
        //$2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
         
    }

    ////////////////////////////
    // Modifiers to use //
    ////////////////////////////

    modifier depositedCollateral() {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintDsc() {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL,DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }


    ////////////////////////////
    // depositCollateral Test //
    ////////////////////////////
    

    function testRevertsIfCollateralZero() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RANDOM", "RAN");
        ERC20Mock(randToken).mint(Alice, STARTING_ERC20_BALANCE);

        vm.startPrank(Alice);
        //vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector, address(randToken)));
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(Alice);
        
        uint256 expectedTotalDscMinted = 0;
        //we use this other function to check the $$$ value of the collateral we 
        //hardcoded in the modifier and compare it with what the contract stored as 
        //the value for the user
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        
        assertEq(totalDscMinted, expectedTotalDscMinted);
        //console.log(collateralValueInUsd); // 10 ether * 2000 = $20,000
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testIfCollateralIsDepositedInDSCEngine() public depositedCollateral {
        //1. deposit collateral
        //2. check starting balance of user and ending balance of dscEngine
        uint256 endingBalOfUser = ERC20Mock(weth).balanceOf(Alice);
        uint256 endingBalOfDscEngine = ERC20Mock(weth).balanceOf(address(engine));
        assertEq(STARTING_ERC20_BALANCE, endingBalOfUser+AMOUNT_COLLATERAL);
        assertEq(endingBalOfDscEngine, AMOUNT_COLLATERAL);
    }

    function testIfCollateralIsDepositedInDSCEngineAndEventEmitted() public  {
        vm.prank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.prank(Alice);
        // Act / Assert
        vm.expectEmit();
        // We emit the event we expect to see in the next call
        emit CollateralDeposited(address(Alice), weth, AMOUNT_COLLATERAL);

        // We perform the call.
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);    
    }

    function testRevertIfDepositWithLessAllowanceGiven() public {

        vm.prank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        uint256 amountMoreThanApproved = 15e18;

        vm.prank(Alice);
        vm.expectRevert();
        engine.depositCollateral(weth, amountMoreThanApproved); 

    }


    function testCanDepositCollateralAndMintDscInOneTrxn() public {
        //1. make a deposit and mint in same function
        //2. compare the expected DSC with the collateral deposited value
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL,DSC_AMOUNT_TO_MINT);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(Alice);
        //collateralValueInUsd = $20,000 (000 000 000 000 000 000)
        //DSC_AMOUNT_TO_MINT = 50 (000 000 000 000 000 000)
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        console.log(collateralValueInUsd);
        uint256 expectedDscMinted = 50e18;
        uint256 expectedDepositedCollateral = AMOUNT_COLLATERAL;

        assertEq(expectedDscMinted, totalDscMinted);
        assertEq(expectedDepositAmount, expectedDepositedCollateral);
    }


    // this test needs it's own setup so the transfer function can be made to always fail
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        //vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(Alice, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(Alice);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    

    ////////////////////////////
    // mintDsc Test ////////////
    ////////////////////////////

    function testCanMintDsc() public depositedCollateral {
        //1. make a deposit of collateral
        //2. check DscMinted of user
        //3. check balanceOf DSC of user
        vm.startPrank(Alice);
        uint256 startingDscBal = dsc.balanceOf(address(Alice));
        engine.mintDsc(DSC_AMOUNT_TO_MINT);
        uint256 endingDscBal = dsc.balanceOf(address(Alice));

        (uint256 totalDscMinted ,) = engine.getAccountInformation(Alice);
        console.log(endingDscBal, totalDscMinted);

        assertEq(startingDscBal+totalDscMinted, endingDscBal);

    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    // function testCannotMintIfHealthFactorWillBreak() public depositedCollateral{
    //     vm.startPrank(Alice);

    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor)); 
    //     engine.mintDsc(25000e18); //we manually cal and assumed this is the amount in $$$
    //     //that would break the health factor, hence the test is expectRevert()
    // }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        //dollar amount to Mint based on collateral price
        uint256 amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision(); 
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
            //since the collateral is at 100% value with mintedDsc, it is not overcollaterized
            //so this is the expectedHealthFactor if we mint this amount of DscMinted
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor)); 
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        
        vm.stopPrank();
    }

    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /////////////////////////////////////
    // redeemCollateral Test ////////////
    /////////////////////////////////////

    function testIfUserCanRedeemZeroAmountOfCollateral() public depositedCollateralAndMintDsc{
        //1. make deposit and mint
        //2. try to redeem zero amount
        vm.startPrank(Alice);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, 0);
        vm.stopPrank();


    }

    function testRedeemCollateralBurnsDscAndRedeemsCollateral() public depositedCollateralAndMintDsc{
        //1. deposit and mint
        //2. redeem an amount
        //3. check if balance of dsc of user has reduced 
        //3b check if balance of weth of user has increaded by AMOUNT_COLLATERAL 
        //4. check if where the burnt tokens are sent to was successful
        vm.startPrank(Alice);
        uint256 userCollateralBalBefore = ERC20Mock(weth).balanceOf(Alice);

        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT); //take out all my collateral and pay debt of only 50, it will break
        
        uint256 userBalanceAfter = dsc.balanceOf(Alice);
        (uint256 totalDscMinted ,) = engine.getAccountInformation(Alice);

        uint256 userCollateralBalAfter = ERC20Mock(weth).balanceOf(Alice);


        vm.stopPrank();
        assertEq(userBalanceAfter, totalDscMinted);
        assertEq(userCollateralBalBefore+AMOUNT_COLLATERAL, userCollateralBalAfter);

    }

    function testRevertIfAmountZeroForRedeemCollateral() public depositedCollateralAndMintDsc{
        
        //1. deposit and mint
        //2. burnDsc
        //3. redeem zero amount
        vm.startPrank(Alice);
        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        engine.burnDsc(DSC_AMOUNT_TO_MINT);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);


    }

    function testCanRedeemCollateral() public depositedCollateralAndMintDsc{
        //1. deposit and mint
        //2. burnDsc
        //3. check health factor
        //4. redeem what wont break health factor
        //5. check balance of weth in user account
        vm.startPrank(Alice);
        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        engine.burnDsc(DSC_AMOUNT_TO_MINT);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(Alice);
        console.log("totalDscMinted: ",totalDscMinted);
        console.log("collateralValueInUsd: ",collateralValueInUsd); //$20,000 (000 000 000 000 000 000)

        uint256 collateralAmountUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 newCollaterlValue = collateralValueInUsd - collateralAmountUsd;
        console.log("newCollaterlValue: ",newCollaterlValue);
        uint256 healthfactor = engine.calculateHealthFactor(totalDscMinted, newCollaterlValue);
        console.log("healthfactor: ",healthfactor);

        uint256 startingUserBal = ERC20Mock(weth).balanceOf(Alice);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL); //NB: this would have reverted if health factor was broken
        uint256 endingUserBal = ERC20Mock(weth).balanceOf(Alice);

        assertEq(endingUserBal, startingUserBal+AMOUNT_COLLATERAL);
        assert(healthfactor > 1);

    }

    function testRevertIfHealthFactorIsBrokenOnRedeemCollateral() public {
        //1. deposit and mint
        //2. burnDsc
        //3. check health factor
        //4. pay back / redeem what leaves you still owing the DscEngine (lowerDscMinted)
        vm.startPrank(Alice);
        
        //NB: DSC_AMOUNT_TO_MINT = 50e18;
        //NB: AMOUNT_COLLATERAL = 10 ETH = $20,000
        //so we are burning like 10e18, meaning we still owe the DscEngine 40e18
        //this will leave us breaking our health facotr if we try to collect all the collateral we have 
        //or as much as would leave us lower than 200% overcollaterized

        

        uint256 wethUsdValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        //so lets say we want to mint something close to this worth

        uint256 dsc_to_mint = wethUsdValue/2;
        console.log("dsc_to_mint: ",dsc_to_mint); //$10,000 (000 000 000 000 000 000)
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL,dsc_to_mint);
        
        dsc.approve(address(engine), dsc_to_mint);
        uint256 lowerDscAmountToBurn = dsc_to_mint * 10/100; 
        console.log("lowerDscAmountToBurn: ",lowerDscAmountToBurn); 
        engine.burnDsc(lowerDscAmountToBurn); //we pay back only 10% of our debt
        

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(Alice);
        console.log("totalDscMinted: ",totalDscMinted); //$9,000 (000 000 000 000 000 000) what we are still owing
        console.log("collateralValueInUsd: ",collateralValueInUsd); //$20,000 (000 000 000 000 000 000)

        //lets try to take out collateral exposing us
        uint256 collateralAmountUsd = engine.getUsdValue(weth, 5 ether); //$10,000
        console.log("collateralAmountUsd: ",collateralAmountUsd);
        uint256 newCollaterlValue = collateralValueInUsd - collateralAmountUsd;
        console.log("newCollaterlValue: ",newCollaterlValue);//$10,000 (000 000 000 000 000 000)

        uint256 healthfactor = (engine.calculateHealthFactor(totalDscMinted, newCollaterlValue))/1e18;
        console.log("healthfactor: ",healthfactor); //0.555555555555555580 
        //so we use 0 because 555555555555555580  will not match what the eroor message data
        //returned in the contract
        
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthfactor));
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);

    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(Alice, Alice, weth, AMOUNT_COLLATERAL);
        vm.startPrank(Alice);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

     // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(Alice, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(Alice);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////////////////////
    // burnDsc Test /////////////////////
    /////////////////////////////////////

     function testCantBurnMoreThanUserHas() public {
        vm.prank(Alice);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintDsc {
        vm.startPrank(Alice);
        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        engine.burnDsc(DSC_AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(Alice);
        assertEq(userBalance, 0);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }



    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintDsc {
        uint256 expectedHealthFactor = 200 ether;
        uint256 healthFactor = engine.getHealthFactor(Alice);
        // $50 minted with $20,000 collateral at 50% liquidation threshold
        //i.e at 50% of the collateral being used to calculate health factor
        // means that we must have $200 and above collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 50 = 200 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }


    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintDsc {
        int256 ethUsdUpdatedPrice = 9e8;  //the dollar value in 8 decimal places
        // 1 ETH = $9 * 10 (AMOUNT_COLLATERAL) = $90
        // Rememeber, we need $100 at all times if we have $50 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice); //the dollar value in 8 decimal places

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(Alice);
        console.log(collateralValueInUsd, totalDscMinted); //90 000000000000000000 50 000000000000000000
        //so you deposited 10 ether, which is now worth $9 each, thats collateral of $90

        uint256 userHealthFactor = engine.getHealthFactor(Alice);
        console.log(userHealthFactor); //0.900000000000000000
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) = 0.9
        assertEq(userHealthFactor, 0.9 ether);
    }


    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        /**
         * Recall that liquidation is paying debt for someone
         * and paying debt is burning DSC Token.
         * so we have modified the DSC Token to set the price of ETH to 0
         * whenever  burn happens, which means making the value of collatereal of the person
         * we are paying debt for to go to 0, directly crashing their helth factor. 
         * Esp cases where you only part paid the collateral
         */
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc) 
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL); 
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT); //10 ETH and $50 DSC

        //(uint256 totalDscMinted, uint256 collateralValueInUsd) = mockDsce.getAccountInformation(Alice);
        //console.log(totalDscMinted, collateralValueInUsd);
        vm.stopPrank();

        
        // Arrange - Liquidator
        uint256 collateralToCover = 1 ether;
        ERC20Mock(weth).mint(Liquidator, collateralToCover); //owner is msg.sender here

        vm.startPrank(Liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);

        uint256 debtToCover = 10 ether; //$10

        //this line makes the liquidator to deposit collateral so he too can have DSC Token to use and pay the debt
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, DSC_AMOUNT_TO_MINT);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 9e8; // 1 ETH = $9
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, Alice, debtToCover);
        vm.stopPrank();
        
        
        //////////////////////****************LOW-LEVEL**********************////////////////////////
        /*
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = mockDsce.getAccountInformation(Alice);
        console.log("totalDscMinted: ", totalDscMinted, "collateralValueInUsd: ",collateralValueInUsd);
        //totalDscMinted:  $50 (000000000000000000) collateralValueInUsd:  $180 (000000000000000000) @1 ETH = $18

        //totalDscMinted:  $50 (000000000000000000) collateralValueInUsd:  $90 (000000000000000000) @1 ETH = $9
  
        uint256 startingUserHealthFactor = mockDsce.getHealthFactor(Alice);
        console.log("startingUserHealthFactor: ",startingUserHealthFactor); //1.800000000000000000 HF is ok  //so you cannot liquidate Alice @1 ETH = $18
        //0.900000000000000000 HF not OK @ 1 ETH = $9

        uint256 tokenAmountFromDebtCovered = mockDsce.getTokenAmountFromUsd(weth, debtToCover);
        console.log("tokenAmountFromDebtCovered: ", tokenAmountFromDebtCovered); //Amount of ETH equivalent to $debtToCover
        //1.111111111111111111 * 9 (ETH price) = $10 debtToCover
        //0.05 ETH * 0.1 = 0.005. The liquidator is getting total of 0.055

        uint256 LIQUIDATION_PRECISION = 100;
        uint256 LIQUIDATION_BONUS = 10;
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; 
        console.log("bonusCollateral: ",bonusCollateral); //bonusCollateral:  0.111111111111111111
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        console.log("totalCollateralToRedeem: ",totalCollateralToRedeem);//1.222222222222222222

        mockDsce._redeemCollateral2(weth, totalCollateralToRedeem, Alice, Liquidator);
        //Alice owed $50, you are paying $10 and taking out $11 (1.222222222222222222) worth of ETH @ 1 ETH = $9
        //Alice is now owing $40 with collateral of $79 (8.77777777778 ETH) 
        //HF here is 0.9875 which is improved 
        uint256 middleUserHealthFactor = mockDsce.getHealthFactor(Alice); //0.987500000000000000

        //but this line actually goes in to set the price to be 1 ETH = $0 in the mockDSCToken, making the HF to fail
        mockDsce._burnDsc2(debtToCover, Alice, Liquidator);
        

        uint256 endingUserHealthFactor = mockDsce.getHealthFactor(Alice);
        console.log("endingUserHealthFactor: ",endingUserHealthFactor); 
        */

    }


    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintDsc {
        uint256 collateralToCover = 20 ether; //$20
        ERC20Mock(weth).mint(Liquidator, collateralToCover);

        vm.startPrank(Liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, DSC_AMOUNT_TO_MINT);
        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, Alice, DSC_AMOUNT_TO_MINT);
        vm.stopPrank();
    }


     modifier liquidated() {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_AMOUNT_TO_MINT); //Debt is $50, collateral of $20,000
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 9e8; // 1 ETH = $9

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(Alice); //Debt is $50, collateral of $90

        uint256 collateralToCover = 50 ether; //$50
        ERC20Mock(weth).mint(Liquidator, collateralToCover);

        vm.startPrank(Liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, DSC_AMOUNT_TO_MINT);
        dsc.approve(address(engine), DSC_AMOUNT_TO_MINT);
        engine.liquidate(weth, Alice, DSC_AMOUNT_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(Liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, DSC_AMOUNT_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, DSC_AMOUNT_TO_MINT) / engine.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110; //6.11111111 ETH ==> 5.555555555555 + (0.1*5.55555555555)
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(Liquidator);
        assertEq(liquidatorDscMinted, DSC_AMOUNT_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(Alice);
        assertEq(userDscMinted, 0);
    }


    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, DSC_AMOUNT_TO_MINT)
            + (engine.getTokenAmountFromUsd(weth, DSC_AMOUNT_TO_MINT) / engine.getLiquidationBonus()); 
            //5.55555555556 + (5.55555555556 * 0.1) = 6.11111111111 ETH
        console.log("amountLiquidated: ", amountLiquidated); //6111111111111111110
        //what happens when the collateral is not even worth the debt and 
        //as such not even enough to have a bonus for the 
        

        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated); //$55
        console.log("usdAmountLiquidated: ",usdAmountLiquidated); //54999999999999999990
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated); //$90 - $55 = $35
        console.log("expectedUserCollateralValueInUsd: ", expectedUserCollateralValueInUsd); //$35 000000000000000010

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(Alice); //$35.000000000000000010
        console.log("userCollateralValueInUsd: ",userCollateralValueInUsd); //35000000000000000010
        uint256 hardCodedExpectedValue = 35000000000000000010; //$35
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }
    
    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(Alice);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(Alice);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(Alice);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(Alice, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }


    function testGetDsc() public {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }












}


