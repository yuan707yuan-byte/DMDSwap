// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DmdSwapFactory} from "../src/core/DmdSwapFactory.sol";
import {DmdSwapPair} from "../src/core/DmdSwapPair.sol";
import {DmdSwapRouter} from "../src/periphery/DmdSwapRouter.sol";
import {DmdNameResolver} from "../src/names/DmdNameResolver.sol";
import {DmdNameRouter} from "../src/names/DmdNameRouter.sol";
import {WDMD} from "../src/token/WDMD.sol";
import {IDMDRegistrarControllerView, IDMDRegistryView} from "../src/interfaces/external/IDMDNamesSystem.sol";

/// @notice One-shot DMDSwap deployment for DMD Diamond mainnet (chain 17771).
///
///   ADMIN=0xYourAdmin forge script script/Deploy.s.sol --rpc-url dmd_mainnet --broadcast --slow \
///       --ledger            # (recommended) or --private-key / --account
///
/// Refuses to deploy unless the chain is 17771 and the official DMD Names system checks out on-chain.
/// Afterwards asserts that ONLY the 24h timelock (proposer/executor/canceller = ADMIN) holds power.
contract Deploy is Script {
    uint256 public constant DMD_MAINNET_CHAIN_ID = 17771;
    uint256 public constant TIMELOCK_DELAY = 24 hours;
    bytes32 internal constant DMD_NODE = 0x9904bf4b5751e3b6a8b75d14c49424160de1a8fa8a90fd5c9fccdeac0503e612;

    // Official DMD Naming System v1.0.0 (DMDcoin/diamond-contracts-registry README)
    address public constant DMD_NAMES_CONTROLLER = 0x04847f99aD1312aFFB1cc6A03a53FEB5fEdd282B;
    address public constant DMD_NAMES_NFT = 0xcba1D8a3b237f2E43B949aE0dfA2e46341823F10;
    address public constant DMD_NAMES_REGISTRY = 0x8AA91989f67e186ce28BfE293bC336b46f6e4fE7;
    address public constant DMD_NAMES_RESOLVER = 0x2C8a0437457da46115484F9DbE7b6966444519D2;

    struct Config {
        address admin; // proposer/executor/canceller of the timelock, guardian, AND fee recipient
        uint16 swapFeeBps; // 30 = 0.30 %
        uint16 protocolShareBps; // 5000 = half of every swap fee directly to admin
        address namesController;
        address expectedNamesNft;
        address expectedRegistry;
        address expectedResolver;
    }

    struct Deployment {
        address timelock;
        address pairImplementation;
        address pairBeacon;
        address wdmd;
        address factory;
        address router;
        address nameResolver;
        address nameRouter;
    }

    error PreflightFailed(string reason);
    error PostflightFailed(string reason);

    function run() external returns (Deployment memory d) {
        if (block.chainid != DMD_MAINNET_CHAIN_ID) revert PreflightFailed("not DMD mainnet (17771)");
        Config memory c = Config({
            admin: vm.envAddress("ADMIN"),
            swapFeeBps: uint16(vm.envOr("SWAP_FEE_BPS", uint256(30))),
            protocolShareBps: uint16(vm.envOr("PROTOCOL_SHARE_BPS", uint256(5_000))),
            namesController: DMD_NAMES_CONTROLLER,
            expectedNamesNft: DMD_NAMES_NFT,
            expectedRegistry: DMD_NAMES_REGISTRY,
            expectedResolver: DMD_NAMES_RESOLVER
        });
        preflight(c);
        vm.startBroadcast();
        d = deploy(c);
        vm.stopBroadcast();
        postflight(c, d);
        _write(d);
    }

    /// @notice Verifies the official DMD Names system on-chain before anything is deployed.
    function preflight(Config memory c) public view {
        if (c.admin == address(0)) revert PreflightFailed("ADMIN not set");
        if (c.admin.code.length != 0) console2.log("note: ADMIN is a contract (e.g. a Safe)");
        if (c.swapFeeBps > 100) revert PreflightFailed("swap fee > 1%");
        if (c.protocolShareBps > 5_000) revert PreflightFailed("protocol share > 50%");
        IDMDRegistrarControllerView ctrl = IDMDRegistrarControllerView(c.namesController);
        if (c.namesController.code.length == 0) revert PreflightFailed("names controller has no code");
        if (ctrl.diamondNames() != c.expectedNamesNft) revert PreflightFailed("names NFT mismatch");
        if (ctrl.registry() != c.expectedRegistry) revert PreflightFailed("names registry mismatch");
        if (ctrl.resolver() != c.expectedResolver) revert PreflightFailed("names resolver mismatch");
        if (IDMDRegistryView(c.expectedRegistry).owner(DMD_NODE) != c.namesController) {
            revert PreflightFailed("controller is not the live .dmd registrar");
        }
        if (!ctrl.valid("alice") || ctrl.valid("Alice")) revert PreflightFailed("controller.valid() unexpected");
    }

    function deploy(Config memory c) public returns (Deployment memory d) {
        address[] memory roles = new address[](1);
        roles[0] = c.admin;
        // admin = proposer + executor (+ canceller by default); no other admin => self-governed timelock
        d.timelock = address(new TimelockController(TIMELOCK_DELAY, roles, roles, address(0)));

        d.pairImplementation = address(new DmdSwapPair());
        d.pairBeacon = address(new UpgradeableBeacon(d.pairImplementation, d.timelock));

        d.wdmd = address(new ERC1967Proxy(address(new WDMD()), abi.encodeCall(WDMD.initialize, (d.timelock))));

        d.factory = address(
            new ERC1967Proxy(
                address(new DmdSwapFactory()),
                abi.encodeCall(
                    DmdSwapFactory.initialize,
                    (d.timelock, c.admin, d.pairBeacon, c.swapFeeBps, c.admin, c.protocolShareBps)
                )
            )
        );

        d.router = address(
            new ERC1967Proxy(
                address(new DmdSwapRouter()), abi.encodeCall(DmdSwapRouter.initialize, (d.timelock, d.factory, d.wdmd))
            )
        );

        d.nameResolver = address(
            new ERC1967Proxy(
                address(new DmdNameResolver()),
                abi.encodeCall(DmdNameResolver.initialize, (d.timelock, c.namesController))
            )
        );

        d.nameRouter = address(
            new ERC1967Proxy(
                address(new DmdNameRouter()),
                abi.encodeCall(DmdNameRouter.initialize, (d.timelock, d.factory, d.wdmd, d.nameResolver))
            )
        );
    }

    /// @notice Proves the final permission state. Any deviation aborts before addresses are published.
    function postflight(Config memory c, Deployment memory d) public view {
        TimelockController tl = TimelockController(payable(d.timelock));
        if (tl.getMinDelay() != TIMELOCK_DELAY) revert PostflightFailed("timelock delay");
        if (!tl.hasRole(tl.PROPOSER_ROLE(), c.admin)) revert PostflightFailed("admin not proposer");
        if (!tl.hasRole(tl.EXECUTOR_ROLE(), c.admin)) revert PostflightFailed("admin not executor");
        if (!tl.hasRole(tl.CANCELLER_ROLE(), c.admin)) revert PostflightFailed("admin not canceller");
        if (tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), c.admin)) revert PostflightFailed("admin is timelock admin");
        if (tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), msg.sender)) revert PostflightFailed("deployer is timelock admin");
        address[6] memory owned = [d.pairBeacon, d.wdmd, d.factory, d.router, d.nameResolver, d.nameRouter];
        for (uint256 i; i < owned.length; ++i) {
            if (Ownable(owned[i]).owner() != d.timelock) revert PostflightFailed("owner is not timelock");
        }
        DmdSwapFactory f = DmdSwapFactory(d.factory);
        if (f.feeTo() != c.admin) revert PostflightFailed("fee recipient is not admin");
        if (f.protocolFeeShareBps() != c.protocolShareBps) revert PostflightFailed("protocol share");
        if (f.swapFeeBps() != c.swapFeeBps) revert PostflightFailed("swap fee");
        if (f.guardian() != c.admin) revert PostflightFailed("guardian");
        if (f.pairBeacon() != d.pairBeacon) revert PostflightFailed("beacon");
        if (UpgradeableBeacon(d.pairBeacon).implementation() != d.pairImplementation) revert PostflightFailed("impl");
        if (DmdSwapRouter(payable(d.router)).factory() != d.factory) revert PostflightFailed("router factory");
        if (DmdSwapRouter(payable(d.router)).WDMD() != d.wdmd) revert PostflightFailed("router wdmd");
        if (DmdNameRouter(payable(d.nameRouter)).nameResolver() != d.nameResolver) revert PostflightFailed("resolver");
        (address ctrl,,, bool enabled) = DmdNameResolver(d.nameResolver).namesSystem();
        if (ctrl != c.namesController || !enabled) revert PostflightFailed("names system");
    }

    function _write(Deployment memory d) internal {
        string memory k = "dmdswap";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "timelock", d.timelock);
        vm.serializeAddress(k, "pairImplementation", d.pairImplementation);
        vm.serializeAddress(k, "pairBeacon", d.pairBeacon);
        vm.serializeAddress(k, "wdmd", d.wdmd);
        vm.serializeAddress(k, "factory", d.factory);
        vm.serializeAddress(k, "router", d.router);
        vm.serializeAddress(k, "nameResolver", d.nameResolver);
        string memory json = vm.serializeAddress(k, "nameRouter", d.nameRouter);
        vm.writeJson(json, "./deployments/dmd-mainnet.json");
        console2.log("Deployment written to deployments/dmd-mainnet.json");
    }
}
