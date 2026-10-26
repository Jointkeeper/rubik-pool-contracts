// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {BlockWitness} from "../src/BlockWitness.sol";

/// Прекомпайлы замоканы (без форка): судится форма события и сжигание газа до `keepGas`.
contract BlockWitnessTest is Test {
    BlockWitness w;
    address constant A = address(0xA);
    address constant B = address(0xB);

    function setUp() public {
        w = new BlockWitness();
        vm.mockCall(address(0x801), abi.encode(A, uint64(0)), abi.encode(uint64(7), uint64(0), uint64(0)));
        vm.mockCall(address(0x801), abi.encode(B, uint64(0)), abi.encode(uint64(9), uint64(0), uint64(0)));
        vm.mockCall(address(0x80F), abi.encode(uint32(0), A), abi.encode(int64(5), uint64(0), uint64(0), int64(4)));
        vm.mockCall(address(0x803), abi.encode(A), abi.encode(uint64(3)));
    }

    function test_recordEmitsBlockAndValues() public {
        vm.roll(123);
        vm.recordLogs();
        // Газ задаётся явно: `gas_limit` профиля — 2^63, без лимита цикл сжигания шёл бы вечно.
        w.record{gas: 300_000}(A, B, 0, 42, 50_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        (uint256 blk, uint256 tag, uint64 sa, uint64 sb, int64 av, int64 raw, uint64 wd) =
            abi.decode(logs[0].data, (uint256, uint256, uint64, uint64, int64, int64, uint64));
        assertEq(blk, 123);
        assertEq(tag, 42);
        assertEq(sa, 7);
        assertEq(sb, 9);
        assertEq(av, 5);
        assertEq(raw, 4);
        assertEq(wd, 3);
    }

    function test_recordBurnsDownToKeep() public {
        uint256 g0 = gasleft();
        w.record{gas: 1_000_000}(A, B, 0, 1, 60_000);
        uint256 spent = g0 - gasleft();
        assertGt(spent, 900_000);          // сожжено почти всё, кроме keepGas
        assertLt(spent, 1_000_000);
    }

    function test_snapshotReportsBlock() public {
        vm.roll(77);
        (uint256 blk, uint64 sa, uint64 sb,,,) = w.snapshot(A, B, 0);
        assertEq(blk, 77);
        assertEq(sa, 7);
        assertEq(sb, 9);
    }
}
