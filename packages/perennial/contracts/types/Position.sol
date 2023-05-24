// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "@equilibria/perennial-v2-oracle/contracts/types/OracleVersion.sol";
import "./ProtocolParameter.sol";
import "./MarketParameter.sol";
import "./Order.sol";

/// @dev Order type
struct Position {
    uint256 id; // TODO: try to remove
    uint256 version;
    UFixed6 maker;
    UFixed6 long;
    UFixed6 short;
    UFixed6 collateral; // TODO: unused in the non-pending and global instance
    UFixed6 deposit; // TODO: unused in the non-pending and global instance
    UFixed6 fee; // TODO: unused in the non-pending instances
}
using PositionLib for Position global;
struct StoredPosition { // TODO: pack this better
    // slot 1
    uint32 _id;
    uint32 _version;
    uint64 _maker;
    uint64 _long;
    uint64 _short;

    // slot 2
    uint88 _collateral;
    uint88 _deposit;
    uint80 _fee;
}
struct PositionStorage { StoredPosition value; }
using PositionStorageLib for PositionStorage global;

/**
 * @title PositionLib
 * @notice Library
 */
library PositionLib {
    function ready(Position memory self, OracleVersion memory latestVersion) internal pure returns (bool) {
        return latestVersion.version >= self.version;
    }

    /// @dev settlement
    function update(Position memory self, Position memory newPosition) internal pure {
        (self.id, self.version, self.maker, self.long, self.short) = (
            newPosition.id,
            newPosition.version,
            newPosition.maker,
            newPosition.long,
            newPosition.short
        );
    }

    /// @dev local update
    function update(
        Position memory self,
        uint256 currentId,
        uint256 currentVersion,
        UFixed6 newMaker,
        UFixed6 newLong,
        UFixed6 newShort,
        UFixed6 newCollateral,
        UFixed6 deposit,
        OracleVersion memory latestVersion,
        MarketParameter memory marketParameter
    ) internal pure returns (Order memory newOrder) {
        (newOrder.maker, newOrder.long, newOrder.short) = (
            Fixed6Lib.from(newMaker).sub(Fixed6Lib.from(self.maker)),
            Fixed6Lib.from(newLong).sub(Fixed6Lib.from(self.long)),
            Fixed6Lib.from(newShort).sub(Fixed6Lib.from(self.short))
        );
        newOrder.registerFee(latestVersion, marketParameter);

        if (self.id != currentId) {
            self.deposit = UFixed6Lib.ZERO;
            self.fee = UFixed6Lib.ZERO;
        }
        (self.id, self.version, self.maker, self.long, self.short, self.collateral, self.deposit, self.fee) = (
            currentId,
            currentVersion,
            newMaker,
            newLong,
            newShort,
            newCollateral.min(UFixed6Lib.MAX_88), // TODO: better way to do this?
            self.deposit.add(deposit),
            self.fee.add(newOrder.fee)
        );
    }

    /// @dev global update
    function update(Position memory self, uint256 currentId, uint256 currentVersion, Order memory order) internal pure {
        if (self.id != currentId) self.fee = UFixed6Lib.ZERO;
        (self.id, self.version, self.maker, self.long, self.short, self.fee) = (
            currentId,
            currentVersion,
            UFixed6Lib.from(Fixed6Lib.from(self.maker).add(order.maker)),
            UFixed6Lib.from(Fixed6Lib.from(self.long).add(order.long)),
            UFixed6Lib.from(Fixed6Lib.from(self.short).add(order.short)),
            self.fee.add(order.fee)
        );
    }

    function magnitude(Position memory self) internal pure returns (UFixed6) {
        return self.long.max(self.short).max(self.maker);
    }

    function major(Position memory self) internal pure returns (UFixed6) {
        return self.long.max(self.short);
    }

    function minor(Position memory self) internal pure returns (UFixed6) {
        return self.long.min(self.short);
    }

    function net(Position memory self) internal pure returns (UFixed6) {
        return Fixed6Lib.from(self.long).sub(Fixed6Lib.from(self.short)).abs();
    }

    function spread(Position memory self) internal pure returns (UFixed6) {
        return net(self).div(major(self));
    }

    function utilization(Position memory self) internal pure returns (UFixed6) {
        return major(self).unsafeDiv(self.maker.add(minor(self)));
    }

    function longSocialized(Position memory self) internal pure returns (UFixed6) {
        return self.maker.add(self.short).min(self.long);
    }

    function shortSocialized(Position memory self) internal pure returns (UFixed6) {
        return self.maker.add(self.long).min(self.short);
    }

    function takerSocialized(Position memory self) internal pure returns (UFixed6) {
        return major(self).min(minor(self).add(self.maker));
    }

    function socialized(Position memory self) internal pure returns (bool) {
        return self.maker.add(self.short).lt(self.long) || self.maker.add(self.long).lt(self.short);
    }

    function singleSided(Position memory self) internal pure returns (bool) {
        return magnitude(self).eq(self.maker.add(self.long).add(self.short));
    }

    function maintenance(
        Position memory self,
        OracleVersion memory currentOracleVersion,
        MarketParameter memory marketParameter
    ) internal pure returns (UFixed6) {
        return magnitude(self).mul(currentOracleVersion.price.abs()).mul(marketParameter.maintenance);
    }

    function sub(Position memory self, Position memory position) internal pure returns (Order memory newOrder) {
        (newOrder.maker, newOrder.long, newOrder.short) = (
            Fixed6Lib.from(self.maker).sub(Fixed6Lib.from(position.maker)),
            Fixed6Lib.from(self.long).sub(Fixed6Lib.from(position.long)),
            Fixed6Lib.from(self.short).sub(Fixed6Lib.from(position.short))
        );
    }
}

library PositionStorageLib {
    error PositionStorageInvalidError();

    function read(PositionStorage storage self) internal view returns (Position memory) {
        StoredPosition memory storedValue =  self.value;

        return Position(
            uint256(storedValue._id),
            uint256(storedValue._version),
            UFixed6.wrap(uint256(storedValue._maker)),
            UFixed6.wrap(uint256(storedValue._long)),
            UFixed6.wrap(uint256(storedValue._short)),
            UFixed6.wrap(uint256(storedValue._collateral)),
            UFixed6.wrap(uint256(storedValue._deposit)),
            UFixed6.wrap(uint256(storedValue._fee))
        );
    }

    function store(PositionStorage storage self, Position memory newValue) internal {
        if (newValue.id > type(uint32).max) revert PositionStorageInvalidError();
        if (newValue.version > type(uint32).max) revert PositionStorageInvalidError();
        if (newValue.maker.gt(UFixed6Lib.MAX_64)) revert PositionStorageInvalidError();
        if (newValue.long.gt(UFixed6Lib.MAX_64)) revert PositionStorageInvalidError();
        if (newValue.short.gt(UFixed6Lib.MAX_64)) revert PositionStorageInvalidError();
        if (newValue.collateral.gt(UFixed6Lib.MAX_88)) revert PositionStorageInvalidError();
        if (newValue.deposit.gt(UFixed6Lib.MAX_88)) revert PositionStorageInvalidError();
        if (newValue.fee.gt(UFixed6Lib.MAX_80)) revert PositionStorageInvalidError();

        self.value = StoredPosition(
            uint32(newValue.id),
            uint32(newValue.version),
            uint64(UFixed6.unwrap(newValue.maker)),
            uint64(UFixed6.unwrap(newValue.long)),
            uint64(UFixed6.unwrap(newValue.short)),
            uint88(UFixed6.unwrap(newValue.collateral)),
            uint88(UFixed6.unwrap(newValue.deposit)),
            uint80(UFixed6.unwrap(newValue.fee))
        );
    }
}