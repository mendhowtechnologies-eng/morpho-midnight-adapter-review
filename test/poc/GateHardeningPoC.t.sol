// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";
import {IKRCompatibleEnterGate} from "../../src/adapters/midnight/gates/IKRCompatibleEnterGate.sol";
import {WhitelistEnterSubGate} from "../../src/adapters/midnight/gates/WhitelistEnterSubGate.sol";

contract FactoryStub {
    mapping(address => bool) public isCreated;

    function setCreated(address a) external {
        isCreated[a] = true;
    }
}

contract Stranger {
    function poke(IKRCompatibleEnterGate gate) external {
        gate.unadmit();
    }
}

/// @dev Plays the registered adapter. Runs admit, check, foreign unadmit and re-check in one call frame,
///      since `admitted` is transient storage and only lives within a transaction.
contract AdmitDriver {
    function run(IKRCompatibleEnterGate gate, address factory, address user, Stranger stranger)
        external
        returns (bool beforeUnadmit, bool afterUnadmit)
    {
        gate.admit(user, factory);
        beforeUnadmit = gate.canIncreaseCredit(user);
        stranger.poke(gate);
        afterUnadmit = gate.canIncreaseCredit(user);
    }
}

/// @notice I-1 and I-2: access-control hardening on the new enter-gate contracts.
contract GateHardeningPoC is Test {
    address roleSetter = makeAddr("roleSetter");
    address adapterAddr = makeAddr("adapter");
    address shareholder = makeAddr("shareholder");
    address stranger = makeAddr("stranger");

    WhitelistEnterSubGate subGate;
    IKRCompatibleEnterGate gate;
    FactoryStub factory;

    function setUp() public {
        subGate = new WhitelistEnterSubGate(roleSetter, roleSetter, false, false);
        gate = new IKRCompatibleEnterGate(address(subGate), true);
        factory = new FactoryStub();
        factory.setCreated(adapterAddr);
        vm.prank(roleSetter);
        gate.addAdmitterFactory(address(factory));
    }

    /// @dev I-1: any address can clear an admission granted by a registered adapter.
    ///      Not reachable mid-take today (no external execution between admit and Midnight's check),
    ///      but the gate relies on that call ordering instead of enforcing who may unadmit.
    function testAnyoneCanUnadmit() public {
        AdmitDriver driver = new AdmitDriver();
        factory.setCreated(address(driver));
        Stranger strangerContract = new Stranger();
        (bool beforeUnadmit, bool afterUnadmit) = driver.run(gate, address(factory), shareholder, strangerContract);
        assertTrue(beforeUnadmit, "admitted by the registered adapter");
        assertFalse(afterUnadmit, "admission cleared by an unrelated contract");
    }

    /// @dev I-2: the role setter moves in one step; a mistyped address (or zero) loses the side for good,
    ///      and with it control over addAdmitterFactory on every IKR gate that uses this subgate.
    function testRoleSetterSingleStepLosesControl() public {
        address typo = address(0xdead);
        vm.prank(roleSetter);
        subGate.setRoleSetter(true, typo);

        vm.prank(roleSetter);
        vm.expectRevert();
        subGate.setRoleSetter(true, roleSetter);

        // The gate's roleSetter is derived from the subgate's credit-side role setter.
        assertEq(gate.roleSetter(), typo, "gate admin now unreachable");
        vm.prank(roleSetter);
        vm.expectRevert();
        gate.addAdmitterFactory(makeAddr("newFactory"));
    }
}
