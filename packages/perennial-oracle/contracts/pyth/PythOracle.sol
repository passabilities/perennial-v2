// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@pythnetwork/pyth-sdk-solidity/AbstractPyth.sol";
import "@equilibria/root/attribute/Instance.sol";
import "@equilibria/root/attribute/Kept.sol";
import "../interfaces/IPythFactory.sol";

/// @title PythOracle
/// @notice Pyth implementation of the IOracle interface.
/// @dev One instance per Pyth price feed should be deployed. Multiple products may use the same
///      PythOracle instance if their payoff functions are based on the same underlying oracle.
///      This implementation only supports non-negative prices.
contract PythOracle is IPythOracle, Instance, Kept {
    /// @dev A Pyth update must come at least this long after a version to be valid
    uint256 constant private MIN_VALID_TIME_AFTER_VERSION = 12 seconds;

    /// @dev A Pyth update must come at most this long after a version to be valid
    uint256 constant private MAX_VALID_TIME_AFTER_VERSION = 15 seconds;

    /// @dev After this amount of time has passed for a version without being committed, the version can be invalidated.
    uint256 constant private GRACE_PERIOD = 1 minutes;

    /// @dev The multiplier for the keeper reward on top of cost
    UFixed18 constant private KEEPER_REWARD_PREMIUM = UFixed18.wrap(1.5e18);

    /// @dev The fixed gas buffer that is added to the keeper reward
    uint256 constant private KEEPER_BUFFER = 80_000;

    /// @dev Pyth contract
    AbstractPyth public immutable pyth;

    /// @dev Pyth price feed id
    bytes32 public id;

    /// @dev List of all requested oracle versions
    uint256[] public versions;

    /// @dev Index in `versions` of the next version a keeper should commit
    uint256 public latestId; // TODO: off-by-one error, first price should be 1
    
    /// @dev Mapping from oracle version to oracle version data
    mapping(uint256 => Fixed6) private _prices;

     /// @notice Initializes the immutable contract state
     /// @param pyth_ Pyth contract
    constructor(AbstractPyth pyth_) {
        pyth = pyth_;
    }

    /// @notice Initializes the contract state
    /// @param id_ price ID for Pyth price feed
    /// @param chainlinkFeed_ Chainlink price feed for rewarding keeper in DSU
    /// @param dsu_ Token to pay the keeper reward in
    function initialize(bytes32 id_, AggregatorV3Interface chainlinkFeed_, Token18 dsu_) external initializer(1) {
        __Instance__initialize();
        __UKept__initialize(chainlinkFeed_, dsu_);

        if (!pyth.priceFeedExists(id_)) revert PythOracleInvalidPriceIdError(id_);

        id = id_;
    }

    /// @notice Records a request for a new oracle version
    /// @dev Original sender to optionally use for callbacks
    function request(address) external onlyAuthorized {
        uint256 currentVersion = current();
        if (versions.length == 0 || versions[versions.length - 1] != currentVersion) versions.push(currentVersion);
    }

    /// @notice Returns the latest synced oracle version and the current oracle version
    /// @return The latest synced oracle version
    /// @return The current oracle version collecting new orders
    function status() external view returns (OracleVersion memory, uint256) {
        return (latest(), current());
    }

    /// @notice Returns the latest synced oracle version
    /// @return latestVersion Latest oracle version
    function latest() public view returns (OracleVersion memory latestVersion) {
        if (latestId == 0) return latestVersion;
        latestVersion = OracleVersion(versions[latestId], _prices[latestId], true);
    }

    /// @notice Returns the current oracle version accepting new orders
    /// @return Current oracle version
    function current() public view returns (uint256) {
        return IPythFactory(address(factory())).current();
    }


    /// @notice Returns the oracle version at version `version`
    /// @param timestamp The timestamp of which to lookup
    /// @return oracleVersion Oracle version at version `version`
    function at(uint256 timestamp) public view returns (OracleVersion memory oracleVersion) {
        Fixed6 price = _prices[timestamp];
        return OracleVersion(timestamp, price, !price.isZero());
    }

    /// @notice Returns the next oracle version to commit
    /// @return version The next oracle version to commit
    function next() external view returns (uint256 version) {
        uint256 nextId = latestId + 1;
        if (versions.length == 0 || nextId >= versions.length) return 0;
        return versions[nextId];
    }

    /// @notice Commits the price represented by `payload` to the next version that needs to be committed
    /// @dev Will revert if there is an earlier versionIndex that could be committed with `payload`
    /// @param versionId The index of the version to commit
    /// @param payload The update data to commit
    function commit(
        uint256 versionId,
        bytes calldata payload
    ) public payable {
        if (versionId == latestId) {
            _commitNonRequested(versionId, payload);
        } else {
            _commitRequested(versionId, payload);
        }
    }

    // TODO: natspec
    function _commitRequested(
        uint256 versionId,
        bytes calldata payload
    ) private keep(KEEPER_REWARD_PREMIUM, KEEPER_BUFFER, "") {
        latestId++;

        if (
            versionId != 0 &&
            versionId != latestId &&
            block.timestamp < versions[versionId - 1] + GRACE_PERIOD
        ) revert PythOracleInvalidVersionError();

        PythStructs.Price memory price = _parsePayload(payload);
        _recordPrice(versions[versionId], price);
    }

    function _commitNonRequested(
        uint256 versionId,
        bytes calldata payload
    ) private {
        PythStructs.Price memory price = _parsePayload(payload);
        uint256 version = price.publishTime - MIN_VALID_TIME_AFTER_VERSION;

        // TODO: check that versionId is virtual latestId, and use that

        if (
            version <= versions[latestId] ||
            (versions.length > latestId + 1 && version >= versions[latestId + 1])
        ) revert PythOracleInvalidVersionError();

        _recordPrice(version, price);
    }

    /// @notice Records `price` as a Fixed6 at version `oracleVersion`
    /// @param oracleVersion The oracle version to record the price at
    function _recordPrice(uint256 oracleVersion, PythStructs.Price memory price) private {
        int256 expo6Decimal = 6 + price.expo;
        _prices[oracleVersion] = (expo6Decimal < 0) ?
            Fixed6.wrap(price.price).div(Fixed6Lib.from(UFixed6Lib.from(10 ** uint256(-expo6Decimal)))) :
            Fixed6.wrap(price.price).mul(Fixed6Lib.from(UFixed6Lib.from(10 ** uint256(expo6Decimal))));
    }

    function _parsePayload(bytes calldata payload) private returns (PythStructs.Price memory price) {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;

        price = pyth.parsePriceFeedUpdates{value: msg.value}(payloads, ids, 0, type(uint64).max)[0].price;
    }

    /// @notice Pulls funds from the factory to reward the keeper
    /// @param keeperFee The keeper fee to pull
    function _raiseKeeperFee(UFixed18 keeperFee, bytes memory) internal override {
        IPythFactory(address(factory())).claim(UFixed6Lib.from(keeperFee, true));
    }

    /// @dev Only allow authorized callers
    modifier onlyAuthorized {
        if (!IOracleProviderFactory(address(factory())).authorized(msg.sender))
            revert OracleProviderUnauthorizedError();
        _;
    }
}
