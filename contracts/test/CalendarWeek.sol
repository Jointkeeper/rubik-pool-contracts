// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

Vm constant CAL_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev Ревью-3b: календарный расчёт бухгалтерии — не чаще одного за календарную неделю (неделя сменяется в понедельник
/// 00:00 UTC, номер — `(t + 3 days) / 7 days`, как `PoolLedgerBase._calWeek`). Стенды бухгалтерии, которым время безразлично,
/// перед календарным расчётом переходят в начало следующей недели — правила расчёта от времени не зависят.
function toNextCalendarWeek() {
    CAL_VM.warp(((block.timestamp + 3 days) / 7 days + 1) * 7 days - 3 days);
}
