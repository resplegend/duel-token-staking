// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IOracle {
    function getLatestRoundData()
        external
        view
        returns (uint256 timestamp, uint256 price);
}
