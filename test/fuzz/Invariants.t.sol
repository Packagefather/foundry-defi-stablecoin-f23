// SPDX-License-Identifier: MIT


//Invariant is the property in our system that must always hold

//waht are our invariants ?
    // 1. Total supply of DSC should be less than the total value of collateral - i.e the collateral USD value must always be more than the total supply of DSC, DSC is already in USD

    // 2. Getter functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import{StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test{

    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;


    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;

    Handler handler;

     function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (, , weth, wbtc,) = helperConfig
            .activeNetworkConfig();
        handler = new Handler(dsce, dsc);
        //this tells the invariant to call all types of function in our dsce or in the handler as the case may be
        //targetContract(address(dsce));
        targetContract(address(handler)); 
        //hey, don't call redeemCollateral, unless there is collateral to redeem

        
        }
        // forge-config: default.invariant.fail-on-revert = true
        function invariant_protocolMustHaveMoreValueThanTotalSupply() public view{
            console.log("hello");
            //get the value of all the collateral in the protocol
            //compare it to all the debt (DSC)
            uint256 totalSupply = dsc.totalSupply();
            uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
            uint256 totalBtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

            uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
            uint256 wbtcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

            console.log("weth value: ", wethValue);
            console.log("wbtc Value: ", wbtcValue);
            console.log("total supply ", totalSupply);
            console.log("timeMintIsCalled: ", handler.timeMintIsCalled());


            assert(wethValue + wbtcValue >= totalSupply);
            
        }

    function invariant_gettersShouldNotRevert() public view {
        dsce.getLiquidationBonus();
        dsce.getPrecision();
    }
}
