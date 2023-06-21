// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@equilibria/root/control/unstructured/UOwnable.sol";
import "@equilibria/root/token/types/Token18.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@pythnetwork/pyth-sdk-solidity/AbstractPyth.sol";
import "../IOracleProvider.sol";

/**
 * @title PythOracle
 * @notice Pyth implementation of the IOracle interface.
 * @dev One instance per Pyth price feed should be deployed. Multiple products may use the same
 *      PythOracle instance if their payoff functions are based on the same underlying oracle.
 *      This implementation only supports non-negative prices.
 */
contract PythOracle is IOracleProvider, UOwnable {
    /// @dev A Pyth update must come at least this long after a version to be valid
    uint256 constant private MIN_VALID_TIME_AFTER_VERSION = 12 seconds;

    /// @dev A Pyth update must come at most this long after a version to be valid
    uint256 constant private MAX_VALID_TIME_AFTER_VERSION = 15 seconds;

    /// @dev After this amount of time has passed for a version without being committed, the version can be invalidated.
    uint256 constant private GRACE_PERIOD = 1 minutes;

    /// @dev Pyth contract
    AbstractPyth public immutable pyth;

    /// @dev Chainlink price feed for rewarding keeper in DSU
    AggregatorV3Interface private immutable chainlinkFeed;

    /// @dev Keepers are incentivized in the DSU token
    Token18 public immutable DSU;

    /// @dev Pyth price feed id
    bytes32 public priceId;

    /// @dev Keepers are incentivized with block.basefee * `_rewardMultiplier`.
    uint256 public rewardMultiplier;

    /// @dev List of all requested oracle versions
    uint256[] public versionList;

    /// @dev Mapping from oracle version to oracle version data
    mapping (uint256 => OracleVersion) private _versions;

    /// @dev Index in `versionList` of the next version a keeper should commit
    uint256 private _nextVersionIndexToCommit;

    error PythOracleInvalidPriceIdError(bytes32 priceId);
    error PythOracleNoNewVersionToCommitError();
    error PythOracleInvalidVersionIndexError();
    error PythOracleInvalidMessageValueError();
    error PythOracleFailedToCalculateRewardError();
    error PythOracleFailedToSendRewardError();

    /**
     * @notice Initializes the immutable contract state
     * @param pyth_ Pyth contract
     * @param chainlinkFeed_ Chainlink price feed for rewarding keeper in DSU
     * @param dsu_ Token to pay the keeper reward in
     */
    constructor(AbstractPyth pyth_, AggregatorV3Interface chainlinkFeed_, Token18 dsu_) {
        pyth = pyth_;
        chainlinkFeed = chainlinkFeed_;
        DSU = dsu_;
    }

    /**
     * @notice Initializes the contract state
     * @param priceId_ price ID for Pyth price feed
     * @param rewardMultiplier_ Multiplier bonus for keeper reward
     */
    function initialize(bytes32 priceId_, uint256 rewardMultiplier_) external initializer(1) {
        __UOwnable__initialize();

        if (!pyth.priceFeedExists(priceId_)) revert PythOracleInvalidPriceIdError(priceId_);

        priceId = priceId_;
        rewardMultiplier = rewardMultiplier_;
    }

    function updateRewardMultiplier(uint256 rewardMultiplier_) external onlyOwner {
        rewardMultiplier = rewardMultiplier_;
    }

    /**
     * @notice Checks for a new price and updates the internal phase annotation state accordingly
     * @return latestVersion The latest synced oracle version
     * @return currentVersion The current oracle version collecting new orders
     */
    function sync() external returns (OracleVersion memory latestVersion, uint256 currentVersion) {
        if (versionList.length == 0 || versionList[versionList.length - 1] != block.timestamp) {
            versionList.push(block.timestamp);
        }

        // TODO: Figure out what to do in the core protocol if no version has ever been committed.
        latestVersion = latest();
        currentVersion = latestVersion.timestamp == 0 ? 0 : block.timestamp;
    }

    /**
     * @notice Returns the latest synced oracle version
     * @return Latest oracle version
     */
    function latest() public view returns (OracleVersion memory) {
        if (_nextVersionIndexToCommit == 0) {
            OracleVersion memory empty;
            return empty;
        }
        return _versions[versionList[_nextVersionIndexToCommit - 1]];
    }

    /**
     * @notice Returns the current oracle version accepting new orders
     * @return Current oracle version
     */
    function current() public view returns (uint256) {
        return block.timestamp;
    }

    /**
     * @notice Returns the oracle version at version `version`
     * @param version The version of which to lookup
     * @return oracleVersion Oracle version at version `version`
     */
    function at(uint256 version) public view returns (OracleVersion memory oracleVersion) {
        return _versions[version];
    }

    /**
     * @notice Commits the price represented by `updateData` to the next version that needs to be committed
     * @dev Will revert if there is an earlier versionIndex that could be committed with `updateData`
     * @param versionIndex The index of the version to commit
     * @param updateData The update data to commit
     * @param rewardRecipient The address that should receive the reward for committing a version.
     */
    function commit(uint256 versionIndex, bytes calldata updateData, address rewardRecipient) external payable {
        // This check isn't necessary since the caller would not be able to produce a valid updateData
        // with an update time corresponding to a null version, but reverting with a specific error is
        // clearer.
        if (_nextVersionIndexToCommit >= versionList.length) revert PythOracleNoNewVersionToCommitError();
        if (versionIndex < _nextVersionIndexToCommit) revert PythOracleInvalidVersionIndexError();

        uint256 versionToCommit = versionList[versionIndex];

        bytes[] memory updateDataList = new bytes[](1);
        updateDataList[0] = updateData;
        bytes32[] memory priceIdList = new bytes32[](1);
        priceIdList[0] = priceId;

        if (msg.value != pyth.getUpdateFee(updateDataList)) revert PythOracleInvalidMessageValueError();

        PythStructs.Price memory pythPrice = pyth.parsePriceFeedUpdates{value: pyth.getUpdateFee(updateDataList)}(
            updateDataList,
            priceIdList,
            SafeCast.toUint64(versionToCommit + MIN_VALID_TIME_AFTER_VERSION),
            SafeCast.toUint64(versionToCommit + MAX_VALID_TIME_AFTER_VERSION)
        )[0].price;

        // Ensure that the keeper is committing the earliest possible version
        if (versionIndex > _nextVersionIndexToCommit) {
            uint256 previousVersion = versionList[versionIndex - 1];
            // We can only skip the previous version if the grace period has expired
            if (block.timestamp <= previousVersion + GRACE_PERIOD) revert PythOracleInvalidVersionIndexError();

            // If the update is valid for the previous version, we can't skip the previous version
            if (
                pythPrice.publishTime >= previousVersion + MIN_VALID_TIME_AFTER_VERSION &&
                pythPrice.publishTime <= previousVersion + MAX_VALID_TIME_AFTER_VERSION
            ) revert PythOracleInvalidVersionIndexError();
        }

        Fixed6 multiplicand = Fixed6Lib.from(pythPrice.price);
        Fixed6 multiplier = Fixed6Lib.from(SafeCast.toInt256(10 ** SafeCast.toUint256(pythPrice.expo > 0 ? pythPrice.expo : -pythPrice.expo)));

        OracleVersion memory oracleVersion = OracleVersion({
            timestamp: versionToCommit,
            price: multiplicand.mul(multiplier),
            valid: true
        });
        _versions[versionToCommit] = oracleVersion;
        _nextVersionIndexToCommit = _nextVersionIndexToCommit + 1;

        (uint80 roundID, int256 price, , uint256 updatedAt, uint80 answeredInRound) = chainlinkFeed.latestRoundData();
        // Check that the Chainlink data is valid
        if (answeredInRound < roundID || updatedAt == 0) {
            revert PythOracleFailedToCalculateRewardError();
        }
        if (price <= 0) {
            revert PythOracleFailedToCalculateRewardError();
        }

        DSU.push(rewardRecipient, UFixed18.wrap(block.basefee * rewardMultiplier * uint256(price) / (10 ** 8)));
    }
}