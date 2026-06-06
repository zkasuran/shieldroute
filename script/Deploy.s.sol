// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {ShieldRouter} from "../src/ShieldRouter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IBatchPool} from "../src/interfaces/IBatchPool.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockConstantProductPool} from "../src/mocks/MockConstantProductPool.sol";

/// @notice Deploys ShieldRouter plus a demo token pair and pool to Mantle Sepolia.
///         Run with:
///           forge script script/Deploy.s.sol:Deploy \
///             --rpc-url mantle_sepolia --broadcast --legacy
///         (Mantle requires the --legacy flag.)
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        MockERC20 token0 = new MockERC20("ShieldDemo0", "SD0");
        MockERC20 token1 = new MockERC20("ShieldDemo1", "SD1");
        MockConstantProductPool pool = new MockConstantProductPool(1_000_000 ether, 1_000_000 ether);

        // 30s commit + 30s reveal windows for a live demo.
        ShieldRouter router =
            new ShieldRouter(IERC20(address(token0)), IERC20(address(token1)), IBatchPool(address(pool)), 30, 30);

        // Seed the router so it can pay out demo fills.
        token0.mint(address(router), 1_000_000 ether);
        token1.mint(address(router), 1_000_000 ether);

        vm.stopBroadcast();

        console.log("token0  :", address(token0));
        console.log("token1  :", address(token1));
        console.log("pool    :", address(pool));
        console.log("router  :", address(router));
    }
}
