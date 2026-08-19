// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ZiaFeeHook} from "../src/ZiaFeeHook.sol";

/// @notice Read-only CREATE2 address miner. This script never broadcasts or deploys.
contract MineZiaFeeHookAddressScript is Script {
    address internal constant RH_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager internal constant RH_POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    uint160 internal constant REQUIRED_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    /// @dev Requires final TREASURY and KEEPER environment variables because both immutable constructor
    ///      arguments alter initcode and therefore the mined CREATE2 salt and address.
    function run() external view returns (address predicted, bytes32 salt) {
        address treasury = vm.envAddress("TREASURY");
        address keeper = vm.envAddress("KEEPER");
        require(treasury != address(0), "MineZiaFeeHook: zero treasury");
        require(keeper != address(0), "MineZiaFeeHook: zero keeper");

        bytes memory constructorArgs = abi.encode(RH_POOL_MANAGER, treasury, keeper);
        (predicted, salt) =
            HookMiner.find(RH_CREATE2_FACTORY, REQUIRED_FLAGS, type(ZiaFeeHook).creationCode, constructorArgs);

        require(uint160(predicted) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS, "MineZiaFeeHook: bad flags");

        console2.log("CREATE2 factory", RH_CREATE2_FACTORY);
        console2.log("PoolManager", address(RH_POOL_MANAGER));
        console2.log("Treasury", treasury);
        console2.log("Keeper", keeper);
        console2.log("Predicted hook", predicted);
        console2.log("Required flag mask", REQUIRED_FLAGS);
        console2.logBytes32(salt);
        console2.logBytes32(keccak256(abi.encodePacked(type(ZiaFeeHook).creationCode, constructorArgs)));
    }
}
