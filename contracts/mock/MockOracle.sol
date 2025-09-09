// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interface/IOracle.sol";

contract MockOracle is IOracle {
    uint256 private _price;
    uint256 private _timestamp;

    constructor(uint256 initialPrice) {
        _price = initialPrice;
        _timestamp = block.timestamp;
    }

    function getLatestRoundData()
        external
        view
        override
        returns (uint256 timestamp, uint256 price)
    {
        return (_timestamp, _price);
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
        _timestamp = block.timestamp;
    }

    function setTimestamp(uint256 newTimestamp) external {
        _timestamp = newTimestamp;
    }
}
