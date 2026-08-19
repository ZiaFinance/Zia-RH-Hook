// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ZiaFeeHook} from "../src/ZiaFeeHook.sol";

/// @notice Mines and deploys the ZiaFeeHook candidate through Foundry's canonical CREATE2 deployer.
/// @dev Do not broadcast until final addresses, source, dependencies, and bytecode are approved.
contract DeployZiaFeeHookScript is Script {
    address internal constant RH_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager internal constant RH_POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    uint160 internal constant REQUIRED_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function run() external returns (ZiaFeeHook deployed) {
        require(block.chainid == 4663, "DeployZiaFeeHook: wrong chain");
        require(address(RH_POOL_MANAGER).code.length != 0, "DeployZiaFeeHook: missing PoolManager");
        require(RH_CREATE2_FACTORY.code.length != 0, "DeployZiaFeeHook: missing CREATE2 factory");

        address treasury = vm.envAddress("TREASURY");
        address keeper = vm.envAddress("KEEPER");
        require(treasury != address(0), "DeployZiaFeeHook: zero treasury");
        require(keeper != address(0), "DeployZiaFeeHook: zero keeper");

        bytes memory constructorArgs = abi.encode(RH_POOL_MANAGER, treasury, keeper);
        (address predicted, bytes32 salt) =
            HookMiner.find(RH_CREATE2_FACTORY, REQUIRED_FLAGS, type(ZiaFeeHook).creationCode, constructorArgs);
        require(predicted.code.length == 0, "DeployZiaFeeHook: address already used");

        // This is a local simulation-only preflight. It proves the compiled implementation declares
        // exactly the permissions encoded in the mined address before startBroadcast is reached.
        bytes memory runtimeCode = vm.getDeployedCode("ZiaFeeHook.sol:ZiaFeeHook");
        vm.etch(predicted, runtimeCode);
        Hooks.Permissions memory declaredPermissions = ZiaFeeHook(predicted).getHookPermissions();
        uint160 declaredFlags = _permissionMask(declaredPermissions);
        vm.etch(predicted, bytes(""));

        require(declaredFlags == REQUIRED_FLAGS, "DeployZiaFeeHook: wrong declared permissions");
        require(
            uint160(predicted) & Hooks.ALL_HOOK_MASK == declaredFlags, "DeployZiaFeeHook: permissions/address mismatch"
        );

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        deployed = new ZiaFeeHook{salt: salt}(RH_POOL_MANAGER, treasury, keeper);
        vm.stopBroadcast();

        require(address(deployed) == predicted, "DeployZiaFeeHook: unexpected address");
        require(_permissionMask(deployed.getHookPermissions()) == REQUIRED_FLAGS, "DeployZiaFeeHook: postcheck failed");
        require(
            uint160(address(deployed)) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS,
            "DeployZiaFeeHook: deployed address flags mismatch"
        );

        console2.log("ZiaFeeHook", address(deployed));
        console2.logBytes32(salt);
    }

    function _permissionMask(Hooks.Permissions memory permissions) private pure returns (uint160 mask) {
        if (permissions.beforeInitialize) mask |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (permissions.afterInitialize) mask |= Hooks.AFTER_INITIALIZE_FLAG;
        if (permissions.beforeAddLiquidity) mask |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (permissions.afterAddLiquidity) mask |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (permissions.beforeRemoveLiquidity) mask |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (permissions.afterRemoveLiquidity) mask |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (permissions.beforeSwap) mask |= Hooks.BEFORE_SWAP_FLAG;
        if (permissions.afterSwap) mask |= Hooks.AFTER_SWAP_FLAG;
        if (permissions.beforeDonate) mask |= Hooks.BEFORE_DONATE_FLAG;
        if (permissions.afterDonate) mask |= Hooks.AFTER_DONATE_FLAG;
        if (permissions.beforeSwapReturnDelta) mask |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterSwapReturnDelta) mask |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterAddLiquidityReturnDelta) mask |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (permissions.afterRemoveLiquidityReturnDelta) mask |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }
}
