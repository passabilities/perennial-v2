// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "@equilibria/root/attribute/interfaces/IInstance.sol";
import "@equilibria/root/attribute/interfaces/IKept.sol";
import "@equilibria/perennial-v2/contracts/interfaces/IOracleProvider.sol";

interface IPythOracle is IOracleProvider, IInstance, IKept {
    error PythOracleInvalidPriceIdError(bytes32 id);
    error PythOracleNoNewVersionToCommitError();
    error PythOracleVersionIndexTooLowError();
    error PythOracleGracePeriodHasNotExpiredError();
    error PythOracleUpdateValidForPreviousVersionError();
    error PythOracleNonIncreasingPublishTimes();
    error PythOracleFailedToCalculateRewardError();
    error PythOracleFailedToSendRewardError();
    error PythOracleVersionTooOldError();
    error PythOracleNonRequestedTooRecentError();

    function initialize(bytes32 id_, AggregatorV3Interface chainlinkFeed_, Token18 dsu_) external;
    function commit(uint256 versionIndex, bytes calldata updateData) external payable;
}
