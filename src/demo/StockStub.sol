// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Fork-only stand-in for a Coinbase stock token. On Base these tokens are built into the chain (their code is the
/// single byte 0xef) and a local fork cannot run them. Aave keeps its own accounting, so a transfer that just
/// succeeds is enough to replay a liquidation; every Aave check stays real.
contract StockStub {
    bytes32 immutable SYM;
    uint8 immutable DEC;

    constructor(bytes32 sym, uint8 dec) {
        SYM = sym;
        DEC = dec;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function decimals() external view returns (uint8) {
        return DEC;
    }

    function symbol() external view returns (string memory s) {
        bytes32 b = SYM;
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        s = new string(n);
        for (uint256 i; i < n; ++i) bytes(s)[i] = b[i];
    }
}
