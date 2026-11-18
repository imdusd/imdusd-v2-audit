// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TwoChains} from "../utils/TwoChains.sol";
import {MockLzEndpoint, MockMessageLib} from "../utils/MockLzEndpoint.sol";
import {ImdBridge} from "../../src/bridge/ImdBridge.sol";
import {Ledger} from "../../src/Ledger.sol";
import {MessagingFee} from "layerzero-v2/protocol/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layerzero-v2/protocol/interfaces/IMessageLibManager.sol";
import {SendParam} from "layerzero-v2/oft/interfaces/IOFT.sol";
import {Governed} from "../../src/Governed.sol";

/// @notice Regression tests for the bridge findings of an earlier internal review (F1-F4).
contract BridgeReviewTest is TwoChains {
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address sendLib;
    address receiveLib;
    address movedLib; // LayerZero's next default
    address dvnA = address(0x1000);
    address dvnB = address(0x2000);
    address dvnC = address(0x3000);

    function setUp() public {
        _setUpChains();
        sendLib = rhSendLib; // the libraries TwoChains._open pins and configures on rh (audit wave 4)
        receiveLib = rhRecvLib;
        movedLib = address(new MockMessageLib());
        // LayerZero's defaults today = the libraries we pin
        rhEp.setDefaultLibraries(HOME_EID, sendLib, receiveLib);
        homeEp.setDefaultLibraries(RH_EID, homeSendLib, homeRecvLib);
        weth.mint(alice, 1000e18);
        vm.startPrank(alice);
        weth.approve(address(rh.ledger), type(uint256).max);
        vm.stopPrank();
        vm.deal(alice, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    /// @dev Three required DVNs (MIN_REQUIRED_DVNS = 3): `a`, `b` and dvnC (0x3000, above both, so the
    /// list stays ascending whenever a < b < 0x3000).
    function _dvns(address a, address b) internal pure returns (address[] memory d) {
        d = new address[](3);
        (d[0], d[1], d[2]) = (a, b, address(0x3000));
    }

    function _uln(uint64 conf, uint8 count, address[] memory req) internal pure returns (bytes memory) {
        return abi.encode(UlnConfig(conf, count, 255, 0, req, new address[](0)));
    }

    function _cfg(address lib, uint32 eid, uint32 configType, bytes memory config) internal pure returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(eid, configType, config);
        return abi.encode(uint8(2), lib, p);
    }

    function _pinSend(uint32 eid, address lib) internal pure returns (bytes memory) {
        return abi.encode(uint8(3), eid, lib);
    }

    function _pinReceive(uint32 eid, address lib) internal pure returns (bytes memory) {
        return abi.encode(uint8(4), eid, lib, uint256(0));
    }

    function _batch(bytes memory a, bytes memory b, bytes memory c) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](3);
        (items[0], items[1], items[2]) = (a, b, c);
        return abi.encode(uint8(6), items);
    }

    function _batch2(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](2);
        (items[0], items[1]) = (a, b);
        return abi.encode(uint8(6), items);
    }

    function _batch4(bytes memory a, bytes memory b, bytes memory c, bytes memory d) internal pure returns (bytes memory) {
        bytes[] memory items = new bytes[](4);
        (items[0], items[1], items[2], items[3]) = (a, b, c, d);
        return abi.encode(uint8(6), items);
    }

    function _govern(ImdBridge b, bytes memory payload) internal {
        vm.prank(safe);
        b.propose(payload);
        _warp(48 hours);
        b.applyPending();
    }

    // ------------------------------------------------------------ F1: pinned libraries

    function test_reviewF1_defaultLibraryMoveNoLongerChangesTheEffectiveConfig() public {
        _open(); // pins + configures both libraries
        bytes memory ours = rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID);
        assertGt(ours.length, 0, "our DVN config verifies inbound packets");
        assertEq(rh.bridge.receiveLibrary(HOME_EID), receiveLib);
        assertEq(rh.bridge.sendLibrary(HOME_EID), sendLib);
        // LayerZero moves its default library (no transaction of ours)
        rhEp.setDefaultLibraries(HOME_EID, movedLib, movedLib);
        (address lib, bool isDefault) = rhEp.getReceiveLibrary(address(rh.bridge), HOME_EID);
        assertEq(lib, receiveLib, "still on the pinned library");
        assertFalse(isDefault);
        assertEq(rhEp.getSendLibrary(address(rh.bridge), HOME_EID), sendLib);
        assertEq(keccak256(rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID)), keccak256(ours), "config unchanged");
    }

    function test_reviewF1_unpinnedOAppFollowsTheDefaultMove() public {
        // the mechanism the pin closes: config set on today's default, not pinned, is lost on a default move (no _open:
        // a path can no longer be opened unpinned, audit wave 4)
        rhEp.setDefaultLibraries(HOME_EID, sendLib, receiveLib);
        vm.prank(address(rh.bridge));
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB)));
        rhEp.setConfig(address(rh.bridge), receiveLib, p);
        assertGt(rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID).length, 0);
        rhEp.setDefaultLibraries(HOME_EID, movedLib, movedLib);
        assertEq(rhEp.effectiveReceiveConfig(address(rh.bridge), HOME_EID).length, 0, "the library's defaults verify now");
    }

    function test_reviewF1_setConfigRefusesAnUnpinnedLibrary() public {
        bytes memory cfg = _cfg(receiveLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB)));
        bytes memory sendCfg = _cfg(sendLib, HOME_EID, 2, _uln(20, 3, _dvns(dvnA, dvnB)));
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.UnpinnedLibrary.selector, HOME_EID, receiveLib));
        rh.bridge.propose(cfg);
        // pinned in the same BATCH: accepted (any position in the batch)
        vm.prank(safe);
        rh.bridge.propose(_batch4(cfg, _pinReceive(HOME_EID, receiveLib), _pinSend(HOME_EID, sendLib), sendCfg));
        vm.prank(safe);
        rh.bridge.cancel();
        // pinned for another eid only: refused
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.UnpinnedLibrary.selector, HOME_EID, receiveLib));
        rh.bridge.propose(_batch(cfg, _pinReceive(40_161, receiveLib), _pinSend(HOME_EID, sendLib)));
        // a library LayerZero moved to (not ours): refused even after we pinned the old one
        _open();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.UnpinnedLibrary.selector, HOME_EID, movedLib));
        rh.bridge.propose(_cfg(movedLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))));
        // a migration = re-pin + config in one BATCH
        _govern(
            rh.bridge,
            _batch2(_pinReceive(HOME_EID, movedLib), _cfg(movedLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))))
        ); // re-pinning the unchanged send library would revert at application (EndpointV2 LZ_SameValue)
        assertEq(rh.bridge.receiveLibrary(HOME_EID), movedLib);
    }

    function test_reviewF1_launchBatchesPinBothLibraries() public pure {
        // the shipped launch BATCHes carry both pins ahead of the config (checked by decoding, offline)
        _assertPins(
            RobinhoodConfigProbe.batch4663(), 30101, 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7, 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043
        );
        _assertPins(
            RobinhoodConfigProbe.batchMainnet(),
            30416,
            0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1,
            0xc02Ab410f0734EFa3F14628780e6e695156024C2
        );
    }

    // ------------------------------------------------------------ F2: DVN floors

    /// @dev Propose a receive config from home (Ethereum: floor 15) on pinned libraries; expect `reason`.
    function _refused(bytes memory uln, uint8 reason) internal {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, reason));
        rh.bridge.propose(_batch(_cfg(receiveLib, HOME_EID, 2, uln), _pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib)));
    }

    function test_reviewF2_refusesOneRequiredDvn() public {
        address[] memory one = new address[](1);
        one[0] = dvnA;
        _refused(_uln(15, 1, one), 3);
    }

    function test_reviewF2_refusesZeroRequiredDvnsMeaningDefaults() public {
        _refused(_uln(15, 0, new address[](0)), 3);
    }

    function test_reviewF2_refusesNilRequiredDvns() public {
        _refused(_uln(15, 255, new address[](0)), 3);
    }

    function test_reviewF2_refusesDvnListNotMatchingCount() public {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (dvnA, dvnB);
        _refused(_uln(15, 3, two), 4);
    }

    function test_reviewF2_refusesTwoRequiredDvns() public {
        // The floor is 3, so the old launch pair alone (e.g. LayerZero Labs + one other) is refused
        address[] memory two = new address[](2);
        (two[0], two[1]) = (dvnA, dvnB);
        _refused(_uln(15, 2, two), 3);
    }

    function test_reviewF2_floorIsThree() public view {
        assertEq(rh.bridge.MIN_REQUIRED_DVNS(), 3);
    }

    function test_reviewF2_refusesZeroDuplicateOrUnsortedDvns() public {
        _refused(_uln(15, 3, _dvns(address(0), dvnB)), 5);
        _refused(_uln(15, 3, _dvns(dvnA, dvnA)), 5); // one DVN counted twice
        _refused(_uln(15, 3, _dvns(dvnB, dvnA)), 5);
    }

    function test_reviewF2_refusesConfirmationsBelowTheSourceFloor() public {
        _refused(_uln(14, 3, _dvns(dvnA, dvnB)), 6); // from Ethereum: 15
        _refused(_uln(0, 3, _dvns(dvnA, dvnB)), 6); // 0 = the library default
        _refused(_uln(type(uint64).max, 3, _dvns(dvnA, dvnB)), 6); // NIL = no confirmations
        // home's SEND config: the source is Ethereum (15 passes); rh's SEND config: the source is 4663 (20 needed)
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, uint8(6)));
        rh.bridge.propose(
            _batch(_cfg(sendLib, HOME_EID, 2, _uln(19, 3, _dvns(dvnA, dvnB))), _pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib))
        );
        vm.prank(safe);
        rh.bridge.propose(
            _batch4(
                _pinSend(HOME_EID, sendLib),
                _pinReceive(HOME_EID, receiveLib),
                _cfg(sendLib, HOME_EID, 2, _uln(20, 3, _dvns(dvnA, dvnB))),
                _cfg(receiveLib, HOME_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB)))
            )
        );
        vm.prank(safe);
        home.bridge.propose(
            _batch4(
                _pinSend(RH_EID, sendLib),
                _pinReceive(RH_EID, receiveLib),
                _cfg(sendLib, RH_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))),
                _cfg(receiveLib, RH_EID, 2, _uln(20, 3, _dvns(dvnA, dvnB)))
            )
        );
        // home RECEIVING from 4663: 20
        vm.prank(safe);
        home.bridge.cancel();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, uint8(6)));
        home.bridge.propose(
            _batch(_cfg(receiveLib, RH_EID, 2, _uln(15, 3, _dvns(dvnA, dvnB))), _pinSend(RH_EID, sendLib), _pinReceive(RH_EID, receiveLib))
        );
    }

    function test_reviewF2_refusesBadOptionalSet() public {
        address[] memory opt = new address[](1);
        opt[0] = dvnC;
        _refused(abi.encode(UlnConfig(15, 3, 1, 2, _dvns(dvnA, dvnB), opt)), 7); // threshold > count
        _refused(abi.encode(UlnConfig(15, 3, 2, 1, _dvns(dvnA, dvnB), opt)), 7); // count != length
        _refused(abi.encode(UlnConfig(15, 3, 1, 0, _dvns(dvnA, dvnB), opt)), 7); // threshold 0 with optionals
        // audit wave 4: 0 = LayerZero's default optional set (merged in by ULN302); NIL must carry no list and no threshold
        _refused(abi.encode(UlnConfig(15, 3, 0, 0, _dvns(dvnA, dvnB), new address[](0))), 7);
        _refused(abi.encode(UlnConfig(15, 3, 255, 0, _dvns(dvnA, dvnB), opt)), 7);
        _refused(abi.encode(UlnConfig(15, 3, 255, 1, _dvns(dvnA, dvnB), new address[](0))), 7);
    }

    function test_reviewF2_refusesUnknownTypeExecutorOnReceiveAndZeroExecutor() public {
        _refusedRaw(_cfg(receiveLib, HOME_EID, 3, ""), 1);
        _refusedRaw(_cfg(receiveLib, HOME_EID, 1, abi.encode(uint32(10_000), address(0x4000))), 1); // executor on a receive lib
        _refusedRaw(_cfg(sendLib, HOME_EID, 1, abi.encode(uint32(10_000), address(0))), 2);
    }

    function _refusedRaw(bytes memory cfg, uint8 reason) internal {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.WeakConfig.selector, reason));
        rh.bridge.propose(_batch(cfg, _pinSend(HOME_EID, sendLib), _pinReceive(HOME_EID, receiveLib)));
    }

    function test_reviewF2_shippedConfigsPassTheFloors() public {
        // the launch configs' shape (3 sorted DVNs, executor on send, 15 from Ethereum / 20 from 4663) is accepted
        address[] memory set = _dvns(dvnA, dvnB);
        SetConfigParam[] memory sp = new SetConfigParam[](2);
        sp[0] = SetConfigParam(HOME_EID, 1, abi.encode(uint32(10_000), address(0x4000)));
        sp[1] = SetConfigParam(HOME_EID, 2, _uln(20, 3, set));
        _govern(
            rh.bridge,
            _batch4(
                _pinSend(HOME_EID, sendLib),
                _pinReceive(HOME_EID, receiveLib),
                abi.encode(uint8(2), sendLib, sp),
                _cfg(receiveLib, HOME_EID, 2, _uln(15, 3, set))
            )
        );
        assertEq(rhEp.configCalls(address(rh.bridge)), 2);
    }

    // ------------------------------------------------------------ F3: void a verified forged payload

    address attacker = makeAddr("attacker");

    /// @dev A forged "home -> rh, `amount` to attacker" packet verified by a compromised DVN set; returns its index on homeEp.
    function _forged(uint256 amount) internal returns (uint256 i, uint64 n, bytes32 sender) {
        sender = _peer(home.bridge);
        bytes memory message = abi.encodePacked(bytes32(uint256(uint160(attacker))), uint64(amount / 1e12));
        i = homeEp.forge(RH_EID, _peer(rh.bridge), sender, message);
        n = homeEp.nonce();
    }

    function test_reviewF3_kelpSequenceGuardianNilifiesAndThePathReopens() public {
        _open();
        (uint256 i, uint64 n, bytes32 sender) = _forged(60_000e18);
        assertFalse(homeEp.deliver(i), "RateLimited: 60k > 50k inbound, stays verified at the endpoint");
        // the Safe: pause + void, both instant (no guardian); the endpoint keeps the forged hash
        vm.startPrank(safe);
        rh.bridge.pause(HOME_EID);
        rh.bridge.voidPayload(homeEp.payloadHashOf(i));
        vm.stopPrank();
        assertEq(rhEp.inboundPayloadHash(address(rh.bridge), HOME_EID, sender, n), homeEp.payloadHashOf(i));
        // the Safe reopens (48h): the forged packet is dead for good here
        _govern(rh.bridge, abi.encode(uint8(5), HOME_EID));
        _warp(2 days);
        assertFalse(homeEp.deliver(i), "voided: does not execute");
        assertEq(rh.usd.balanceOf(attacker), 0);
        // honest traffic flows again on the same peer (its first send takes nonce n: verify overwrites the forged hash)
        deal(address(home.usd), alice, 100e18, true);
        _sendFrom(alice, 100e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        assertEq(rh.usd.balanceOf(alice), 100e18);
    }

    function test_reviewF3_withoutVoidingTheForgedPacketMintsAfterReopening() public {
        // the finding as it stood: pause + reopen does nothing for an already-verified packet
        _open();
        (uint256 i,,) = _forged(40_000e18);
        vm.prank(safe);
        rh.bridge.pause(HOME_EID);
        assertFalse(homeEp.deliver(i));
        _govern(rh.bridge, abi.encode(uint8(5), HOME_EID));
        assertTrue(homeEp.deliver(i), "verified payload still executable");
        // above DELAY_THRESHOLD it is queued, not minted; uncancelled, anyone claims it after DELAY
        assertEq(rh.usd.balanceOf(attacker), 0);
        assertEq(rh.bridge.queued(), 40_000e18);
        // QUEUE_BREAKER 50,000 (whales): 40,000 queued is under the breaker, so the path stays open and
        // the finding's end state needs only the Safe not cancelling within DELAY: anyone claims it then
        assertLe(rh.bridge.queued(), rh.bridge.DEFAULT_QUEUE_BREAKER());
        (,, bool tripped,,,,) = rh.bridge.breakers(HOME_EID);
        assertFalse(tripped);
        bytes32 k = _claimKey(homeEp, i);
        _warp(rh.bridge.DEFAULT_DELAY() - 1);
        vm.expectRevert();
        rh.bridge.claim(HOME_EID, k); // not due: the Safe's DELAY to cancel
        _warp(1);
        rh.bridge.claim(HOME_EID, k);
        assertEq(rh.usd.balanceOf(attacker), 40_000e18);
    }

    function test_reviewF3_timelockedBurnAndSkipOnlyOnAPausedPath() public {
        _open();
        (uint256 i, uint64 n, bytes32 sender) = _forged(60_000e18);
        bytes memory burnIt = abi.encode(uint8(10), HOME_EID, sender, n, homeEp.payloadHashOf(i));
        // the head nonce (above lazyInboundNonce) cannot be burned on EndpointV2: refused at proposal (audit wave 4), paused or not
        vm.prank(safe);
        vm.expectRevert(ImdBridge.InfeasibleEndpointAct.selector);
        rh.bridge.propose(burnIt);
        vm.prank(safe);
        rh.bridge.pause(HOME_EID);
        vm.prank(safe);
        vm.expectRevert(ImdBridge.InfeasibleEndpointAct.selector);
        rh.bridge.propose(burnIt);
        // nor skipped: it holds a payload
        vm.prank(safe);
        vm.expectRevert(ImdBridge.InfeasibleEndpointAct.selector);
        rh.bridge.propose(abi.encode(uint8(8), HOME_EID, sender, n));
        // skip a nonce that was never verified: only the first nonce with no hash (n + 1)
        _govern(rh.bridge, abi.encode(uint8(8), HOME_EID, sender, uint64(n + 1)));
        assertEq(rhEp.lazyInboundNonce(address(rh.bridge), HOME_EID, sender), n + 1);
        // n now sits at or below lazyInboundNonce with its hash: burnable for good
        _govern(rh.bridge, burnIt);
        assertEq(rhEp.inboundPayloadHash(address(rh.bridge), HOME_EID, sender, n), bytes32(0));
        assertFalse(homeEp.reverify(i), "burned: not re-verifiable");
        assertFalse(homeEp.deliver(i));
        // a void naming this chain's own eid is refused
        vm.prank(safe);
        vm.expectRevert(ImdBridge.BadPayload.selector);
        rh.bridge.propose(abi.encode(uint8(9), RH_EID, sender, n, bytes32(0)));
    }

    function test_instantActsAreTheGovernorsOnly() public {
        _open();
        (uint256 i, uint64 n,) = _forged(1_000e18);
        bytes32 h = homeEp.payloadHashOf(i);
        vm.startPrank(attacker);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.bridge.voidPayload(h);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.bridge.hold(HOME_EID, n);
        vm.expectRevert(Governed.NotGovernor.selector);
        rh.bridge.pause(HOME_EID);
        vm.stopPrank();
        vm.prank(safe);
        rh.bridge.voidPayload(h);
        assertFalse(homeEp.deliver(i));
        // the endpoint was not touched: once the timelock lifts the void it runs on the proof the endpoint kept
        _govern(rh.bridge, abi.encode(uint8(11), h));
        assertTrue(homeEp.deliver(i));
    }

    // ------------------------------------------------------------ F6: native fee exact

    /// @dev Funds alice BEFORE any expectRevert (deal's own calls would consume it), then sends.
    function _fund(uint256 amount) internal {
        deal(address(home.usd), alice, amount, true);
    }

    function _sendValue(uint256 value, uint256 declared, uint256 amount) internal {
        SendParam memory p = SendParam(RH_EID, bytes32(uint256(uint160(alice))), amount, 0, "", "", "");
        vm.prank(alice);
        home.bridge.send{value: value}(p, MessagingFee(declared, 0), alice);
    }

    function test_reviewF6_overpaymentRefusedNotStranded() public {
        _open();
        uint256 fee = homeEp.FEE();
        _fund(100e18);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotEnoughNative.selector, fee * 3));
        _sendValue(fee * 3, fee, 100e18);
        _sendValue(fee, fee, 100e18);
        assertEq(address(home.bridge).balance, 0, "nothing left behind");
    }

    function test_reviewF6_strandedBalanceCannotFundTheNextSender() public {
        _open();
        uint256 fee = homeEp.FEE();
        vm.deal(address(home.bridge), 1 ether); // e.g. an executor's native drop on lzReceive
        // declaring more than sent used to be paid from the bridge's balance and refunded to the caller
        _fund(100e18);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotEnoughNative.selector, 0));
        _sendValue(0, fee, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.NotEnoughNative.selector, fee));
        _sendValue(fee, 1 ether, 100e18);
        assertEq(address(home.bridge).balance, 1 ether);
    }

    // ------------------------------------------------------------ F7: limit lowering + zero amounts

    function _inbound(ImdBridge b, uint32 eid) internal view returns (uint256 limit, uint256 inFlight) {
        (uint128 l,, uint128 f,) = b.inbound(eid);
        (limit, inFlight) = (l, f);
    }

    /// @dev Fill rh's inbound window from home (50k) with honest traffic.
    function _fillInbound() internal {
        deal(address(home.usd), alice, 50_000e18, true);
        _sendFrom(alice, 50_000e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        assertEq(rh.bridge.availableIn(HOME_EID), 0);
    }

    /// @dev rh's OUTBOUND (to home): lowering an INBOUND limit now needs a paused path (audit wave 4), where nothing arrives,
    /// so the scaling is exercised on the outbound side, which shares `_setLimit`.
    function _outbound(ImdBridge b, uint32 eid) internal view returns (uint256 limit, uint256 inFlight) {
        (uint128 l,, uint128 f,) = b.outbound(eid);
        (limit, inFlight) = (l, f);
    }

    function _sendFromRh(address from, uint256 amount) internal {
        deal(address(rh.usd), from, amount, true);
        SendParam memory p = SendParam(HOME_EID, bytes32(uint256(uint160(from))), amount, 0, "", "", "");
        uint256 fee = rhEp.FEE();
        vm.prank(from);
        rh.bridge.send{value: fee}(p, MessagingFee(fee, 0), from);
    }

    function test_reviewF7_loweringALimitScalesWhatIsInFlight() public {
        _open();
        // the Safe lowers rh's outbound 10k -> 1k a day; the window is filled in the block it applies
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), 1_000e18, IN_LIMIT));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _sendFromRh(alice, OUT_LIMIT);
        assertEq(rh.bridge.availableOut(HOME_EID), 0);
        rh.bridge.applyPending();
        (uint256 limit, uint256 inFlight) = _outbound(rh.bridge, HOME_EID);
        assertEq(limit, 1_000e18);
        assertEq(inFlight, 1_000e18, "full window stays full, scaled: 10k/10k -> 1k/1k");
        assertEq(rh.bridge.availableOut(HOME_EID), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(rh.bridge.availableOut(HOME_EID), 1_000e18, "one window at the new rate, not 10 days");
    }

    function test_reviewF7_halfUsedWindowStaysHalfUsedAfterALowering() public {
        _open();
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), 2_000e18, IN_LIMIT));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _sendFromRh(alice, 5_000e18);
        rh.bridge.applyPending();
        (, uint256 inFlight) = _outbound(rh.bridge, HOME_EID);
        assertEq(inFlight, 1_000e18);
        assertEq(rh.bridge.availableOut(HOME_EID), 1_000e18);
    }

    function test_reviewF7_loweringAnInboundLimitNeedsAPausedPath() public {
        _open();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ImdBridge.PathOpen.selector, HOME_EID));
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 1_000e18));
        vm.prank(safe);
        rh.bridge.pause(HOME_EID);
        _govern(rh.bridge, _path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 1_000e18));
        (uint256 limit,) = _inbound(rh.bridge, HOME_EID);
        assertEq(limit, 1_000e18);
    }

    function test_reviewF7_raisingKeepsTheAbsoluteAmount() public {
        _open();
        vm.prank(safe);
        rh.bridge.propose(_path(HOME_EID, _peer(home.bridge), OUT_LIMIT, 100_000e18));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        deal(address(home.usd), alice, 10_000e18, true);
        _sendFrom(alice, 10_000e18);
        assertTrue(homeEp.deliver(homeEp.packetCount() - 1));
        rh.bridge.applyPending();
        (, uint256 inFlight) = _inbound(rh.bridge, HOME_EID);
        assertEq(inFlight, 10_000e18, "a raise is not scaled");
        assertEq(rh.bridge.availableIn(HOME_EID), 90_000e18);
    }

    function test_reviewF7_zeroAmountMessageDoesNotSnapTheWindow() public {
        _open();
        _fillInbound();
        (, uint256 before) = _inbound(rh.bridge, HOME_EID);
        // a zero-amount packet from the real peer: refused (audit wave 4: it would consume a nonce), moves no window
        bytes memory zero = abi.encodePacked(bytes32(uint256(uint160(attacker))), uint64(0));
        uint256 i = homeEp.forge(RH_EID, _peer(rh.bridge), _peer(home.bridge), zero);
        assertFalse(homeEp.deliver(i));
        (, uint256 after_) = _inbound(rh.bridge, HOME_EID);
        assertEq(after_, before);
        assertEq(rh.bridge.availableIn(HOME_EID), 0);
    }

    function test_reviewF7_zeroAmountSendRefused() public {
        _open();
        deal(address(home.usd), alice, 1e18, true);
        SendParam memory p = SendParam(RH_EID, bytes32(uint256(uint160(alice))), 1e11, 0, "", "", ""); // dust only
        uint256 fee = homeEp.FEE();
        vm.prank(alice);
        vm.expectRevert(ImdBridge.ZeroAmount.selector);
        home.bridge.send{value: fee}(p, MessagingFee(fee, 0), alice);
    }

    function _sendFrom(address from, uint256 amount) internal {
        SendParam memory p = SendParam(RH_EID, bytes32(uint256(uint160(from))), amount, 0, "", "", "");
        uint256 fee = homeEp.FEE();
        vm.prank(from);
        home.bridge.send{value: fee}(p, MessagingFee(fee, 0), from);
    }

    function _assertPins(bytes memory batch, uint32 eid, address s, address r) internal pure {
        (, bytes[] memory items) = abi.decode(batch, (uint8, bytes[]));
        assertEq(items.length, 6); // SET_PATH, SET_DELAY, both pins, both configs
        (uint8 k0, uint32 e0) = abi.decode(items[1], (uint8, uint32));
        assertEq(k0, 15);
        assertEq(e0, eid);
        (uint8 k1, uint32 e1, address l1) = abi.decode(items[2], (uint8, uint32, address));
        (uint8 k2, uint32 e2, address l2, uint256 grace) = abi.decode(items[3], (uint8, uint32, address, uint256));
        assertEq(k1, 3);
        assertEq(e1, eid);
        assertEq(l1, s);
        assertEq(k2, 4);
        assertEq(e2, eid);
        assertEq(l2, r);
        assertEq(grace, 0);
    }
}

import {RobinhoodConfig} from "../../script/DeployConfig.sol";

library RobinhoodConfigProbe {
    function batch4663() internal pure returns (bytes memory) {
        return RobinhoodConfig.launchBatch4663(RobinhoodConfig.mainnetPath(bytes32(uint256(1))));
    }

    function batchMainnet() internal pure returns (bytes memory) {
        return RobinhoodConfig.launchBatchMainnet(RobinhoodConfig.robinhoodPathOnMainnet(bytes32(uint256(1))));
    }
}
