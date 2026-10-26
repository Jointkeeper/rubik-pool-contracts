// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title Моки HyperCore для anvil-стенда keeper'а (`contracts/diff/vault_keeper_stand.pytxt`).
/// @notice Ставятся `anvil_setCode` по адресам `HLConstants`: прекомпайлы читаются «сырым» `staticcall(abi.encode(...))`
/// без селектора — его разбирает `fallback`. Состояние Core (балансы, активация) ведёт питоновский «Core» стенда через
/// сеттеры; действия CoreWriter только СОБЫТИЕ — исполняет их тот же «Core» ПОСЛЕ блока и может молча отклонить (R8c).
/// Селекторы сеттеров не равны нулю, а сырой вызов прекомпайла начинается с 12 нулевых байт адреса — коллизии нет.
contract SpotBalanceMock {
    mapping(address => mapping(uint64 => uint64)) internal bal;

    function setBal(address user, uint64 token, uint64 total) external {
        bal[user][token] = total;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (address user, uint64 token) = abi.decode(data, (address, uint64));
        return abi.encode(bal[user][token], uint64(0), uint64(0));
    }
}

contract CoreUserExistsMock {
    mapping(address => bool) internal exists;

    function setExists(address user, bool v) external {
        exists[user] = v;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        address user = abi.decode(data, (address));
        return abi.encode(exists[user]);
    }
}

contract CoreWriterMock {
    event RawAction(address indexed sender, bytes data);

    function sendRawAction(bytes calldata data) external {
        emit RawAction(msg.sender, data);
    }
}

/// @notice `markPx(uint32 perp)` -> uint64 (цена · 10^(6 − szDecimals), `PrecompileLib.normalizedMarkPx`).
contract MarkPxMock {
    mapping(uint32 => uint64) internal px;

    function setPx(uint32 perp, uint64 v) external {
        px[perp] = v;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        uint32 perp = abi.decode(data, (uint32));
        return abi.encode(px[perp]);
    }
}

/// @notice `position(address, uint32)` (POSITION2) -> (szi, entryNtl, isolatedRawUsd, leverage, isIsolated).
contract Position2Mock {
    mapping(address => mapping(uint32 => int64)) internal szi;

    function setSzi(address user, uint32 perp, int64 v) external {
        szi[user][perp] = v;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (address user, uint32 perp) = abi.decode(data, (address, uint32));
        return abi.encode(szi[user][perp], uint64(0), int64(0), uint32(1), false);
    }
}

/// @notice `accountMarginSummary(uint32 dex, address)` -> (accountValue, marginUsed, ntlPos, rawUsd).
contract AccountMarginSummaryMock {
    mapping(address => int64) internal av;

    function setAv(address user, int64 v) external {
        av[user] = v;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (, address user) = abi.decode(data, (uint32, address));
        return abi.encode(av[user], uint64(0), uint64(0), int64(0));
    }
}

/// @notice `withdrawable(address)` -> uint64.
contract WithdrawableMock {
    mapping(address => uint64) internal w;

    function setW(address user, uint64 v) external {
        w[user] = v;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        address user = abi.decode(data, (address));
        return abi.encode(w[user]);
    }
}
