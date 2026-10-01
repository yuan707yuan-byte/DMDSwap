// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DmdSwapFactory} from "../../src/core/DmdSwapFactory.sol";
import {DmdSwapPair} from "../../src/core/DmdSwapPair.sol";
import {DmdSwapRouter} from "../../src/periphery/DmdSwapRouter.sol";
import {DmdNameResolver} from "../../src/names/DmdNameResolver.sol";
import {DmdNameRouter} from "../../src/names/DmdNameRouter.sol";
import {WDMD} from "../../src/token/WDMD.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @dev Write-side interfaces of the OFFICIAL DMD Names contracts (deployed from build artifacts of
///      DMDcoin/diamond-contracts-registry @ e37c376, see test/fixtures/dmd-names/SOURCE.txt).
interface IDMDController {
    function register(string calldata name) external payable;
    function activate(string calldata name) external payable;
    function renew(string calldata name) external;
    function moderateName(address owner, string calldata name, string calldata reason, string calldata notes)
        external;
    function mintingFee() external view returns (uint256);
    function getActivationFee(address who) external view returns (uint256);
    function valid(string memory name) external pure returns (bool);
}

interface IDMDNamesNFT {
    function setRegistrar(address registrar) external;
    function transferFrom(address from, address to, uint256 tokenId) external payable;
    function transferFee() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IDMDRegistryAdmin {
    function setSubnodeOwner(bytes32 node, bytes32 label, address owner) external returns (bytes32);
}

abstract contract Fixture is Test {
    uint256 internal constant DELAY = 24 hours;
    uint16 internal constant FEE_BPS = 30; // 0.30 % total swap fee
    uint16 internal constant PROTOCOL_SHARE_BPS = 5_000; // half of it goes directly to admin

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal reinsertPot = makeAddr("reinsertPot");
    address internal dmdDao = makeAddr("dmdDao");

    TimelockController internal timelock;
    UpgradeableBeacon internal beacon;
    DmdSwapFactory internal factory;
    DmdSwapRouter internal router;
    DmdNameResolver internal nameResolver;
    DmdNameRouter internal nameRouter;
    WDMD internal wdmd;

    // official DMD Names system
    IDMDController internal dmdController;
    IDMDNamesNFT internal dmdNames;
    address internal dmdRegistry;
    address internal dmdResolver;

    MockERC20 internal tokA;
    MockERC20 internal tokB;
    MockERC20 internal tokC;

    function setUp() public virtual {
        vm.warp(1_760_000_000); // realistic timestamp (Oct 2025)
        _deployDmdNames();
        _deployDex();
        tokA = new MockERC20("Token A", "TKA", 18);
        tokB = new MockERC20("Token B", "TKB", 18);
        tokC = new MockERC20("Token C", "TKC", 6);
        address[4] memory users = [alice, bob, carol, attacker];
        for (uint256 i; i < users.length; ++i) {
            vm.deal(users[i], 1_000_000 ether);
            tokA.mint(users[i], 1e30);
            tokB.mint(users[i], 1e30);
            tokC.mint(users[i], 1e24);
            vm.startPrank(users[i]);
            tokA.approve(address(router), type(uint256).max);
            tokB.approve(address(router), type(uint256).max);
            tokC.approve(address(router), type(uint256).max);
            tokA.approve(address(nameRouter), type(uint256).max);
            tokB.approve(address(nameRouter), type(uint256).max);
            tokC.approve(address(nameRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deployDmdNames() internal {
        bytes32 dmdLabel = keccak256("dmd");
        bytes32 reverseLabel = keccak256("reverse");
        bytes32 reverseNode = keccak256(abi.encodePacked(bytes32(0), reverseLabel));

        address regImpl = deployCode("test/fixtures/dmd-names/DMDRegistry.json");
        dmdRegistry = address(new ERC1967Proxy(regImpl, abi.encodeWithSignature("initialize(address)", dmdDao)));

        address namesImpl = deployCode("test/fixtures/dmd-names/DMDNames.json");
        dmdNames = IDMDNamesNFT(
            address(
                new ERC1967Proxy(
                    namesImpl,
                    abi.encodeWithSignature(
                        "initialize(address,address,uint256,string)", dmdDao, reinsertPot, 0.5 ether, "ipfs://"
                    )
                )
            )
        );

        address resImpl = deployCode("test/fixtures/dmd-names/DMDResolver.json");
        dmdResolver =
            address(new ERC1967Proxy(resImpl, abi.encodeWithSignature("initialize(address)", dmdRegistry)));

        address ctrlImpl = deployCode("test/fixtures/dmd-names/DMDRegistrarController.json");
        dmdController = IDMDController(
            address(
                new ERC1967Proxy(
                    ctrlImpl,
                    abi.encodeWithSignature(
                        "initialize(address,address,address,address,address)",
                        dmdDao,
                        reinsertPot,
                        address(dmdNames),
                        dmdRegistry,
                        dmdResolver
                    )
                )
            )
        );

        vm.startPrank(dmdDao);
        dmdNames.setRegistrar(address(dmdController));
        IDMDRegistryAdmin(dmdRegistry).setSubnodeOwner(bytes32(0), dmdLabel, address(dmdController));
        IDMDRegistryAdmin(dmdRegistry).setSubnodeOwner(bytes32(0), reverseLabel, dmdDao);
        IDMDRegistryAdmin(dmdRegistry).setSubnodeOwner(reverseNode, keccak256("addr"), address(dmdController));
        vm.stopPrank();
    }

    function _deployDex() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        beacon = new UpgradeableBeacon(address(new DmdSwapPair()), address(timelock));

        wdmd = WDMD(payable(address(new ERC1967Proxy(address(new WDMD()), abi.encodeCall(WDMD.initialize, (address(timelock)))))));

        factory = DmdSwapFactory(
            address(
                new ERC1967Proxy(
                    address(new DmdSwapFactory()),
                    abi.encodeCall(
                        DmdSwapFactory.initialize,
                        (address(timelock), admin, address(beacon), FEE_BPS, admin, PROTOCOL_SHARE_BPS)
                    )
                )
            )
        );

        router = DmdSwapRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new DmdSwapRouter()),
                        abi.encodeCall(DmdSwapRouter.initialize, (address(timelock), address(factory), address(wdmd)))
                    )
                )
            )
        );

        nameResolver = DmdNameResolver(
            address(
                new ERC1967Proxy(
                    address(new DmdNameResolver()),
                    abi.encodeCall(DmdNameResolver.initialize, (address(timelock), address(dmdController)))
                )
            )
        );

        nameRouter = DmdNameRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new DmdNameRouter()),
                        abi.encodeCall(
                            DmdNameRouter.initialize,
                            (address(timelock), address(factory), address(wdmd), address(nameResolver))
                        )
                    )
                )
            )
        );
    }

    // ─────────────────────────────────────────── helpers

    /// @dev Full governance path: admin schedules, 24h passes, admin executes.
    function _govern(address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encode(target, data, block.timestamp));
        vm.prank(admin);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _addLiq(address who, address a, address b, uint256 amtA, uint256 amtB) internal returns (address pair) {
        vm.prank(who);
        router.addLiquidity(a, b, amtA, amtB, 0, 0, who, block.timestamp);
        pair = factory.getPair(a, b);
    }

    function _addLiqDMD(address who, address token, uint256 amtToken, uint256 amtDMD) internal returns (address) {
        vm.prank(who);
        router.addLiquidityDMD{value: amtDMD}(token, amtToken, 0, 0, who, block.timestamp);
        return factory.getPair(token, address(wdmd));
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _path3(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        (p[0], p[1], p[2]) = (a, b, c);
    }

    function _registerName(address who, string memory name) internal {
        uint256 fee = dmdController.mintingFee();
        vm.prank(who);
        dmdController.register{value: fee}(name);
    }
}
