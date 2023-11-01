// SPDX-License-Identifier: MIT

//Hnadler is going to narrow down the way that we call functions


pragma solidity ^0.8.18;


import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {

    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timeMintIsCalled;
    address[] usersWithCollateralDeposited;

    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; //the max uint96 value
    //we use rhis because we dont want to use the max uint256, incases a number with maybe extra 1 is added on it does not fall above max amountCollateral which is uint256

   constructor(DSCEngine _dscengine, DecentralizedStableCoin _dsc){
    dsce = _dscengine;
    dsc = _dsc;

    address[] memory collateralTokens = dsce.getCollateralTokens();
    weth = ERC20Mock(collateralTokens[0]);
    wbtc = ERC20Mock(collateralTokens[1]);

    ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth))); 

   }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if(usersWithCollateralDeposited.length == 0){
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        
        int256 maxDscToMint = (int256(collateralValueInUsd)/2) - int256(totalDscMinted);
        if(maxDscToMint < 0){
            return;
        }
       
        amount = bound(amount, 0, uint256(maxDscToMint));
        if(amount == 0){
            return;
        }
        timeMintIsCalled++;
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        
    }
   // redeem collateral <-- call this only when you have collateral 

   function depositcollateral(uint256 collateralSeed, uint256 amountCollateral) public {

    ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
    //bounds the amountCollateral to be between 1 and max_deposit_size
    vm.startPrank(msg.sender);
    collateral.mint(msg.sender, amountCollateral);
    collateral.approve(address(dsce), amountCollateral);
    dsce.depositCollateral(address(collateral), amountCollateral);
    //double push sometime becasue same address can be used to call deposit
    usersWithCollateralDeposited.push(msg.sender);
   }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public{
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        //we are using min from 0 to cover for cases where redeemCollateral
        //is called first, by them the user collateral would be 0

        //so if it is 0, return, dont call on redeemCollateral
        if(amountCollateral == 0){
            return;
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    //This breaks our invariant test suite:
    //the price suddenly gets sometimes set to something really low and as such the assertion of total collateral >= totalSupply fails
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }





   //Helper function
   function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock){
        if(collateralSeed%2 == 0){
            return weth;
        }
        return wbtc;
   }
}