// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDT — токен стенда «Минута»
/// @notice ERC-20 стенда: «Mock USDT», «mUSDT», шесть знаков после запятой,
///         как у USDT (раздел 2 спецификации).
/// @dev Учебный стенд, а не продакшн.
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "mUSDT") {}

    /// @notice Шесть знаков после запятой, как у USDT.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Выпуск токенов.
    /// @dev Только для стенда: публичная функция без ограничений,
    ///      выпустить может кто угодно и сколько угодно.
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
