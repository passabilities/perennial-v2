// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import "./Version.sol";
import "./Position.sol";

/// @dev Local type
struct Local {
    uint256 currentId;
    Fixed6 collateral;
    UFixed6 claimable;
    UFixed6 reward;
    uint256 liquidation;
}
using LocalLib for Local global;
struct StoredLocal {
    uint32 _currentId;
    int56 _collateral;
    uint56 _claimable;
    uint56 _reward;
    uint56 _liquidation;
}
struct LocalStorage { uint256 value; }
using LocalStorageLib for LocalStorage global;

/**
 * @title LocalLib
 * @notice Library
 */
library LocalLib {
    /**
     * @notice Settled the account's position to oracle version `toOracleVersion`
     * @param self The struct to operate on
     */
    function accumulate(
        Local memory self,
        Position memory fromPosition,
        Position memory toPosition,
        Version memory fromVersion,
        Version memory toVersion
    ) internal pure {
        // position
        if (toVersion.valid) {
            Fixed6 collateralAmount = toVersion.makerValue.accumulated(fromVersion.makerValue, fromPosition.maker)
                .add(toVersion.longValue.accumulated(fromVersion.longValue, fromPosition.long))
                .add(toVersion.shortValue.accumulated(fromVersion.shortValue, fromPosition.short));
            UFixed6 rewardAmount = toVersion.makerReward.accumulated(fromVersion.makerReward, fromPosition.maker)
                .add(toVersion.longReward.accumulated(fromVersion.longReward, fromPosition.long))
                .add(toVersion.shortReward.accumulated(fromVersion.shortReward, fromPosition.short));
            Fixed6 feeAmount = Fixed6Lib.from(toPosition.fee);

            self.collateral = self.collateral.add(collateralAmount).sub(feeAmount);
            self.reward = self.reward.add(rewardAmount);
        }

        // collateral
        self.collateral = self.collateral.add(Fixed6Lib.from(toPosition.deposit));
        if (self.collateral.gt(Fixed6Lib.from(toPosition.collateral))) {
            self.claimable = self.claimable.add(toPosition.collateral.sub(UFixed6Lib.from(self.collateral)));
            self.collateral = Fixed6Lib.from(toPosition.collateral);
        }
    }

    function liquidate(
        Local memory self,
        Position memory position,
        OracleVersion memory latestOracleVersion,
        uint256 currentVersion,
        MarketParameter memory marketParameter,
        ProtocolParameter memory protocolParameter
    ) internal pure returns (UFixed6 liquidationFee) {
        liquidationFee = position.maintenance(latestOracleVersion, marketParameter)
            .max(protocolParameter.minCollateral)
            .mul(protocolParameter.liquidationFee);

        self.collateral = self.collateral.sub(Fixed6Lib.from(liquidationFee));
        self.liquidation = currentVersion;
    }

    function clearReward(Local memory self) internal pure {
        self.reward = UFixed6Lib.ZERO;
    }

    function clearClaimable(Local memory self) internal pure {
        self.claimable = UFixed6Lib.ZERO;
    }
}

library LocalStorageLib { // TODO: automate this storage format to save contract size
    error LocalStorageInvalidError();

    function read(LocalStorage storage self) internal view returns (Local memory) {
        uint256 value = self.value;
        return Local(
            uint256(value << 224) >> (256 - 32),
            Fixed6.wrap(int256(value << 168) >> (256 - 56)),
            UFixed6.wrap(uint256(value << 112) >> (256 - 56)),
            UFixed6.wrap(uint256(value << 56) >> (256 - 56)),
            uint256(value) >> (256 - 56)
        );
    }

    function store(LocalStorage storage self, Local memory newValue) internal {
        if (newValue.currentId > type(uint32).max) revert LocalStorageInvalidError();
        if (newValue.collateral.gt(Fixed6Lib.MAX_56)) revert LocalStorageInvalidError();
        if (newValue.collateral.lt(Fixed6Lib.MIN_56)) revert LocalStorageInvalidError();
        if (newValue.claimable.gt(UFixed6Lib.MAX_56)) revert LocalStorageInvalidError();
        if (newValue.reward.gt(UFixed6Lib.MAX_56)) revert LocalStorageInvalidError();
        if (newValue.liquidation > type(uint56).max) revert LocalStorageInvalidError();

        uint256 encoded =
            uint256(newValue.currentId << (256 - 32)) >> 224 |
            uint256(Fixed6.unwrap(newValue.collateral) << (256 - 56)) >> 168 |
            uint256(UFixed6.unwrap(newValue.claimable) << (256 - 56)) >> 112 |
            uint256(UFixed6.unwrap(newValue.reward) << (256 - 56)) >> 56 |
            uint256(newValue.liquidation << (256 - 56));
        assembly {
            sstore(self.slot, encoded)
        }
    }
}