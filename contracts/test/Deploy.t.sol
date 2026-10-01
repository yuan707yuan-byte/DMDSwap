// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Fixture} from "./utils/Fixture.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DmdSwapFactory} from "../src/core/DmdSwapFactory.sol";
import {DmdNameResolver} from "../src/names/DmdNameResolver.sol";

/// @notice Runs the real deploy script logic (preflight -> deploy -> postflight) against a local
///         instance of the official DMD Names system.
contract DeployScriptTest is Fixture {
    Deploy internal script;

    function setUp() public override {
        super.setUp();
        script = new Deploy();
    }

    function _cfg() internal view returns (Deploy.Config memory) {
        return Deploy.Config({
            admin: admin,
            swapFeeBps: 30,
            protocolShareBps: 5_000,
            namesController: address(dmdController),
            expectedNamesNft: address(dmdNames),
            expectedRegistry: dmdRegistry,
            expectedResolver: dmdResolver
        });
    }

    function test_deployScript_endToEnd() public {
        Deploy.Config memory c = _cfg();
        script.preflight(c);
        Deploy.Deployment memory d = script.deploy(c);
        script.postflight(c, d);
        assertEq(DmdSwapFactory(d.factory).feeTo(), admin);
        assertEq(DmdSwapFactory(d.factory).protocolFeeShareBps(), 5_000);
        _registerName(alice, "alice");
        assertEq(DmdNameResolver(d.nameResolver).resolve("alice"), alice);
    }

    function test_preflight_rejectsWrongNamesAddresses() public {
        Deploy.Config memory c = _cfg();
        c.expectedNamesNft = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(Deploy.PreflightFailed.selector, "names NFT mismatch"));
        script.preflight(c);
        c = _cfg();
        c.admin = address(0);
        vm.expectRevert(abi.encodeWithSelector(Deploy.PreflightFailed.selector, "ADMIN not set"));
        script.preflight(c);
    }

    function test_run_refusesNonMainnetChain() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.PreflightFailed.selector, "not DMD mainnet (17771)"));
        script.run();
    }
}
