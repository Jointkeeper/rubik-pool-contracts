// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PrecompileLib} from "hyper-evm-lib/PrecompileLib.sol";

/// Свидетель видимости по блокам (e103 T1(а)). Каждая транзакция `record` читает прекомпайлы
/// ДВУХ адресов и пишет событие с `block.number`, то есть наблюдение подписано блоком, в котором
/// оно сделано, — а не временем опроса RPC. Исторический `eth_call` для этого не годится: замер
/// 18.10 (testnet) — прекомпайл на старом блоке отдаёт ТЕКУЩЕЕ состояние Core.
///
/// `record` сжигает газ до остатка `keepGas`: две такие транзакции не помещаются в один малый
/// блок, поэтому очередь подписанных заранее `record` (nonce n+1..n+K за действием с nonce n)
/// ложится по одной на блок — b, b+1, b+2, … Что легло на самом деле, судит номер блока в
/// событии, а не это ожидание. Денег контракт не держит и ничего не пишет в Core.
contract BlockWitness {
    event Seen(
        uint256 blk,
        uint256 tag,
        uint64 spotA,
        uint64 spotB,
        int64 accountValueA,
        int64 rawUsdA,
        uint64 withdrawableA
    );

    function _read(address a, address b, uint64 token)
        internal
        view
        returns (uint64 sa, uint64 sb, int64 av, int64 raw, uint64 wd)
    {
        sa = PrecompileLib.spotBalance(a, token).total;
        sb = PrecompileLib.spotBalance(b, token).total;
        PrecompileLib.AccountMarginSummary memory m = PrecompileLib.accountMarginSummary(0, a);
        av = m.accountValue;
        raw = m.rawUsd;
        wd = PrecompileLib.withdrawable(a);
    }

    function record(address a, address b, uint64 token, uint256 tag, uint256 keepGas) external {
        (uint64 sa, uint64 sb, int64 av, int64 raw, uint64 wd) = _read(a, b, token);
        emit Seen(block.number, tag, sa, sb, av, raw, wd);
        while (gasleft() > keepGas) {}
    }

    function snapshot(address a, address b, uint64 token)
        external
        view
        returns (uint256 blk, uint64 sa, uint64 sb, int64 av, int64 raw, uint64 wd)
    {
        (sa, sb, av, raw, wd) = _read(a, b, token);
        blk = block.number;
    }
}
