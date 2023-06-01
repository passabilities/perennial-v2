//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import "./interfaces/IVault.sol";
import "@equilibria/root/control/unstructured/UInitializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./VaultDefinition.sol";
import "./types/Account.sol";
import "./types/Checkpoint.sol";

// TODO: only pull out what you can from collateral when really unbalanced
// TODO: make sure maker fees are supported
// TODO: assumes no one can create an order for the vault (check if liquidation / shortfall break this model)
// TODO: add or remove? assets
// TODO: maxRedeem extra logic

/**
 * @title Vault
 * @notice ERC4626 vault that manages a 50-50 position between long-short markets of the same payoff on Perennial.
 * @dev Vault deploys and rebalances collateral between the corresponding long and short markets, while attempting to
 *      maintain `targetLeverage` with its open positions at any given time. Deposits are only gated in so much as to cap
 *      the maximum amount of assets in the vault. The long and short markets are expected to have the same oracle and
 *      opposing payoff functions.
 *
 *      The vault has a "delayed mint" mechanism for shares on deposit. After depositing to the vault, a user must wait
 *      until the next settlement of the underlying products in order for shares to be reflected in the getters.
 *      The shares will be fully reflected in contract state when the next settlement occurs on the vault itself.
 *      Similarly, when redeeming shares, underlying assets are not claimable until a settlement occurs.
 *      Each state changing interaction triggers the `settle` flywheel in order to bring the vault to the
 *      desired state.
 *      In the event that there is not a settlement for a long period of time, keepers can call the `sync` method to
 *      force settlement and rebalancing. This is most useful to prevent vault liquidation due to PnL changes
 *      causing the vault to be in an unhealthy state (far away from target leverage)
 *
 */
contract Vault is IVault, VaultDefinition, UInitializable {
    /// @dev The name of the vault
    string public name;

    mapping(uint256 => Registration) private _registrations;

    /// @dev Mapping of allowance across all users
    mapping(address => mapping(address => UFixed6)) public allowance;

    /// @dev Global accounting state variables
    AccountStorage private _account;

    /// @dev Per-account accounting state variables
    mapping(address account => AccountStorage) private _accounts;

    /// @dev Per-id accounting state variables
    mapping(uint256 id => CheckpointStorage) private _checkpoints;

    /**
     * @notice Constructor for VaultDefinition
     * @param factory_ The factory contract
     * @param targetLeverage_ The target leverage for the vault
     * @param maxCollateral_ The maximum amount of collateral that can be held in the vault
     * @param marketDefinitions_ The market definitions for the vault
     */
    constructor(
        IFactory factory_,
        UFixed6 targetLeverage_,
        UFixed6 maxCollateral_,
        MarketDefinition[] memory marketDefinitions_
    )
    VaultDefinition(factory_, targetLeverage_, maxCollateral_, marketDefinitions_)
    { }

    function totalSupply() external view returns (UFixed6) { return _account.read().shares; }
    function balanceOf(address account) external view returns (UFixed6) { return _accounts[account].read().shares; }
    function totalUnclaimed() external view returns (UFixed6) { return _account.read().assets; }
    function unclaimed(address account) external view returns (UFixed6) { return _accounts[account].read().assets; }

    function totalAssets() public view returns (Fixed6) {
        Checkpoint memory checkpoint = _checkpoints[_account.read().latest].read();
        return checkpoint.assets
            .add(Fixed6Lib.from(checkpoint.deposit))
            .sub(Fixed6Lib.from(checkpoint.toAssets(checkpoint.redemption)));
    }

    function totalShares() public view returns (UFixed6) {
        Checkpoint memory checkpoint = _checkpoints[_account.read().latest].read();
        return checkpoint.shares.sub(checkpoint.redemption).add(checkpoint.toShares(checkpoint.deposit));
    }

    /**
     * @notice Converts a given amount of assets to shares
     * @param assets Number of assets to convert to shares
     * @return Amount of shares for the given assets
     */
    function convertToShares(UFixed6 assets) external view returns (UFixed6) {
        (UFixed6 _totalAssets, UFixed6 _totalShares) =
            (UFixed6Lib.from(totalAssets().max(Fixed6Lib.ZERO)), totalShares());
        return _totalAssets.isZero() ? assets : _totalAssets.muldiv(_totalShares, _totalAssets);
    }

    /**
     * @notice Converts a given amount of shares to assets
     * @param shares Number of shares to convert to assets
     * @return Amount of assets for the given shares
     */
    function convertToAssets(UFixed6 shares) external view returns (UFixed6) {
        (UFixed6 _totalAssets, UFixed6 _totalShares) =
            (UFixed6Lib.from(totalAssets().max(Fixed6Lib.ZERO)), totalShares());
        return _totalShares.isZero() ? shares : shares.muldiv(_totalAssets, _totalShares);
    }

    /**
     * @notice Initializes the contract state
     * @param name_ ERC20 asset name
     */
    function initialize(string memory name_) external initializer(1) {
        name = name_;

        Context memory context = _settle(address(0));

        // set or reset allowance compliant with both an initial deployment or an upgrade
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            asset.approve(address(markets(marketId).market), UFixed18Lib.ZERO);
            asset.approve(address(markets(marketId).market));

            if (address(_registrations[marketId].market) == address(0)) {
                _registrations[marketId].market = markets(marketId).market;
                _registrations[marketId].initialId = context.currentId - 1;
            }

            if (_registrations[marketId].market != markets(marketId).market) revert VaultMarketMismatchError();
        }
    }

    /**
     * @notice Syncs `account`'s state up to current
     * @dev Also rebalances the collateral and position of the vault without a deposit or withdraw
     * @param account The account that should be synced
     */
    function settle(address account) public {
        Context memory context = _settle(account);
        _rebalance(context, UFixed6Lib.ZERO);
        _saveContext(context, account);
    }

    /**
     * @notice Deposits `assets` assets into the vault, returning shares to `account` after the deposit settles.
     * @param assets The amount of assets to deposit
     * @param account The account to deposit on behalf of
     */
    function deposit(UFixed6 assets, address account) external {
        Context memory context = _settle(account);

        if (assets.gt(_maxDeposit(context))) revert VaultDepositLimitExceededError();
        if (context.latestId < context.local.latest) revert VaultExistingOrderError();

        context.global.deposit =  context.global.deposit.add(assets);
        context.local.latest = context.currentId;
        context.local.deposit = assets;
        context.checkpoint.deposit = context.checkpoint.deposit.add(assets);

        asset.pull(msg.sender, _toU18(assets));

        _rebalance(context, UFixed6Lib.ZERO);
        _saveContext(context, account);

        emit Deposit(msg.sender, account, context.currentId, assets);
    }

    /**
     * @notice Redeems `shares` shares from the vault
     * @dev Does not return any assets to the user due to delayed settlement. Use `claim` to claim assets
     *      If account is not msg.sender, requires prior spending approval
     * @param shares The amount of shares to redeem
     * @param account The account to redeem on behalf of
     */
    function redeem(UFixed6 shares, address account) external {
        if (msg.sender != account) _consumeAllowance(account, msg.sender, shares);

        Context memory context = _settle(account);
        if (shares.gt(_maxRedeem(context, account))) revert VaultRedemptionLimitExceededError();
        if (context.latestId < context.local.latest) revert VaultExistingOrderError();

        context.global.redemption =  context.global.redemption.add(shares);
        context.local.latest = context.currentId;
        context.local.redemption = shares;
        context.checkpoint.redemption = context.checkpoint.redemption.add(shares);

        context.local.shares = context.local.shares.sub(shares);
        context.global.shares = context.global.shares.sub(shares);

        _rebalance(context, UFixed6Lib.ZERO);
        _saveContext(context, account);

        emit Redemption(msg.sender, account, context.currentId, shares);
    }

    /**
     * @notice Claims all claimable assets for account, sending assets to account
     * @param account The account to claim for
     */
    function claim(address account) external {
        Context memory context = _settle(account);

        UFixed6 unclaimedAmount = context.local.assets;
        UFixed6 unclaimedTotal = context.global.assets;
        context.local.assets = UFixed6Lib.ZERO;
        context.global.assets = unclaimedTotal.sub(unclaimedAmount);
        emit Claim(msg.sender, account, unclaimedAmount);

        // pro-rate if vault has less collateral than unclaimed
        UFixed6 claimAmount = unclaimedAmount;
        UFixed6 totalCollateral = UFixed6Lib.from(_collateral(context).max(Fixed6Lib.ZERO));
        if (totalCollateral.lt(unclaimedTotal))
            claimAmount = claimAmount.muldiv(totalCollateral, unclaimedTotal);

        _rebalance(context, claimAmount);

        _saveContext(context, account);

        asset.push(account, _toU18(claimAmount));
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's shares
     * @param spender Address which can spend operate on shares
     * @param amount Amount of shares that spender can operate on
     * @return bool true if the approval was successful, otherwise reverts
     */
    function approve(address spender, UFixed6 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice The maximum available deposit amount
     * @dev Only exact when vault is synced, otherwise approximate
     * @return Maximum available deposit amount
     */
    function maxDeposit(address) external view returns (UFixed6) {
        return _maxDeposit(_loadContextForRead(address(0)));
    }

    /**
     * @notice The maximum available redeemable amount
     * @dev Only exact when vault is synced, otherwise approximate
     * @param account The account to redeem for
     * @return Maximum available redeemable amount
     */
    function maxRedeem(address account) external view returns (UFixed6) {
        return _maxRedeem(_loadContextForRead(account), account);
    }

    /**
     * @notice Hook that is called before every stateful operation
     * @dev Settles the vault's account on both the long and short product, along with any global or user-specific deposits/redemptions
     * @param account The account that called the operation, or 0 if called by a keeper.
     * @return context The current epoch contexts for each market
     */
    function _settle(address account) private returns (Context memory context) {
        context = _loadContextForWrite(account);

        // process pending deltas
        while (context.latestId > context.global.latest) {
            Checkpoint memory checkpoint = _checkpoints[context.global.latest + 1].read(); // TODO: convert checkpoint to start / complete
            checkpoint.complete(_collateral(context, context.global.latest + 1));
            _checkpoints[context.global.latest + 1].store(checkpoint);
            context.global.process(checkpoint, checkpoint.deposit, checkpoint.redemption, context.global.latest + 1);
        }
        if (context.latestId >= context.local.latest) {
            Checkpoint memory checkpoint = _checkpoints[context.local.latest].read();
            context.local.process(checkpoint, context.local.deposit, context.local.redemption, context.local.latest);
        }

        // sync data for new id
        context.checkpoint.start(
            context.global.shares,
            Fixed6Lib.from(_toU6(asset.balanceOf()))
                .sub(Fixed6Lib.from(context.global.deposit.add(context.global.assets)))
        );
    }

    /**
     * @notice Rebalances the collateral and position of the vault
     * @dev Rebalance is executed on best-effort, any failing legs of the strategy will not cause a revert
     * @param claimAmount The amount of assets that will be withdrawn from the vault at the end of the operation
     */
    function _rebalance(Context memory context, UFixed6 claimAmount) private {
        Fixed6 collateralInVault = _collateral(context).sub(Fixed6Lib.from(claimAmount));
        UFixed6 minCollateral = factory.parameter().minCollateral;

        // if negative assets, skip rebalance
        if (collateralInVault.lt(Fixed6Lib.ZERO)) return;

        // Compute available collateral
        UFixed6 collateral = UFixed6Lib.from(collateralInVault);
        if (collateral.muldiv(minWeight, totalWeight).lt(minCollateral)) collateral = UFixed6Lib.ZERO;

        // Compute available assets
        UFixed6 assets = UFixed6Lib.from(
                collateralInVault
                    .sub(Fixed6Lib.from(context.global.assets.add(context.global.deposit)))
                    .max(Fixed6Lib.ZERO)
            )
            .mul(context.global.shares.unsafeDiv(context.global.shares.add(context.global.redemption)))
            .add(context.global.deposit);
        if (assets.muldiv(minWeight, totalWeight).lt(minCollateral)) assets = UFixed6Lib.ZERO;

        Target[] memory targets = _computeTargets(context, collateral, assets);

        // Remove collateral from markets above target
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            if (context.markets[marketId].collateral.gt(targets[marketId].collateral))
                _update(context.markets[marketId], markets(marketId).market, targets[marketId]);
        }

        // Deposit collateral to markets below target
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            if (context.markets[marketId].collateral.lte(targets[marketId].collateral))
                _update(context.markets[marketId], markets(marketId).market, targets[marketId]);
        }
    }

    function _computeTargets(
        Context memory context,
        UFixed6 collateral,
        UFixed6 assets
    ) private view returns (Target[] memory targets) {
        targets = new Target[](totalMarkets);

        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            MarketDefinition memory marketDefinition = markets(marketId);

            UFixed6 marketAssets = assets.muldiv(marketDefinition.weight, totalWeight);
            if (context.markets[marketId].closed) marketAssets = UFixed6Lib.ZERO;

            targets[marketId].collateral = Fixed6Lib.from(collateral.muldiv(marketDefinition.weight, totalWeight));
            targets[marketId].position = marketAssets.mul(targetLeverage).div(context.markets[marketId].price);
        }
    }

    /**
     * @notice Adjusts the position on `market` to `targetPosition`
     * @param market The market to adjust the vault's position on
     * @param target The new state to target
     */
    function _update(MarketContext memory marketContext, IMarket market, Target memory target) private {
        // compute headroom until hitting taker amount
        if (target.position.lt(marketContext.currentPositionAccount)) {
            UFixed6 makerAvailable = marketContext.currentPosition.gt(marketContext.currentNet) ?
                marketContext.currentPosition.sub(marketContext.currentNet) :
                UFixed6Lib.ZERO;
            target.position = marketContext.currentPositionAccount
                .sub(marketContext.currentPositionAccount.sub(target.position).min(makerAvailable));
        }

        // compute headroom until hitting makerLimit
        if (target.position.gt(marketContext.currentPositionAccount)) {
            UFixed6 makerAvailable = marketContext.makerLimit.gt(marketContext.currentPosition) ?
                marketContext.makerLimit.sub(marketContext.currentPosition) :
                UFixed6Lib.ZERO;
            target.position = marketContext.currentPositionAccount
                .add(target.position.sub(marketContext.currentPositionAccount).min(makerAvailable));
        }

        // issue position update
        market.update(address(this), target.position, UFixed6Lib.ZERO, UFixed6Lib.ZERO, target.collateral);
    }

    /**
     * @notice Decrements `spender`s allowance for `account` by `amount`
     * @dev Does not decrement if approval is for -1
     * @param account Address of allower
     * @param spender Address of spender
     * @param amount Amount to decrease allowance by
     */
    function _consumeAllowance(address account, address spender, UFixed6 amount) private {
        if (allowance[account][spender].eq(UFixed6Lib.MAX)) return;
        allowance[account][spender] = allowance[account][spender].sub(amount);
    }

    /**
     * @notice Loads the context for the given `account`, settling the vault first
     * @param account Account to load the context for
     * @return Epoch context
     */
    function _loadContextForWrite(address account) private returns (Context memory) {
        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            markets(marketId).market.settle(address(this));
        }

        return _loadContextForRead(account);
    }

    /**
     * @notice Loads the context for the given `account`
     * @param account Account to load the context for
     * @return context Epoch context
     */
    function _loadContextForRead(address account) private view returns (Context memory context) {
        context.latestId = type(uint256).max;
        context.latestVersion = type(uint256).max;
        context.markets = new MarketContext[](totalMarkets);

        for (uint256 marketId; marketId < totalMarkets; marketId++) {
            MarketDefinition memory marketDefinition = markets(marketId);
            MarketParameter memory marketParameter = marketDefinition.market.parameter();
            uint256 currentVersion = marketParameter.oracle.current();

            context.markets[marketId].closed = marketParameter.closed;
            context.markets[marketId].makerLimit = marketParameter.makerLimit;

            // global
            Global memory global = marketDefinition.market.global();
            Position memory currentPosition = marketDefinition.market.pendingPosition(global.currentId);
            Position memory latestPosition = marketDefinition.market.position();
            OracleVersion memory latestOracleVersion = marketParameter.oracle.at(latestPosition.version);
            marketParameter.payoff.transform(latestOracleVersion);

            context.markets[marketId].price = latestOracleVersion.price.abs();
            context.markets[marketId].currentPosition = currentPosition.maker;
            context.markets[marketId].currentNet = currentPosition.net();
            if (latestPosition.version < context.latestVersion) {
                context.latestId = latestPosition.id;
                context.latestVersion = latestPosition.version;
            }

            // local
            Local memory local = marketDefinition.market.locals(address(this));
            currentPosition = marketDefinition.market.pendingPositions(address(this), local.currentId);

            context.markets[marketId].currentPositionAccount = currentPosition.maker;
            context.markets[marketId].collateral = local.collateral;

            if (local.liquidation > context.liquidation) context.liquidation = local.liquidation;
            if (marketId == 0) context.currentId = currentVersion > currentPosition.version ? local.currentId + 1 : local.currentId;
        }

        context.checkpoint = _checkpoints[context.currentId].read();
        context.global = _account.read();
        context.local = _accounts[account].read();
    }

    function _saveContext(Context memory context, address account) private {
        _checkpoints[context.currentId].store(context.checkpoint);
        _account.store(context.global);
        _accounts[account].store(context.local);
    }

    /**
     * @notice Calculates whether or not the vault is in an unhealthy state at the provided epoch
     * @param context Epoch context to calculate health
     * @return bool true if unhealthy, false if healthy
     */
    function _unhealthy(Context memory context) private view returns (bool) {
        Checkpoint memory checkpoint = _checkpoints[context.latestId].read(); // latest basis will always be complete
        return (!checkpoint.shares.isZero() && checkpoint.assets.lte(Fixed6Lib.ZERO)) || (context.liquidation > context.latestVersion);
    }

    /**
     * @notice The maximum available deposit amount at the given epoch
     * @param context Epoch context to use in calculation
     * @return Maximum available deposit amount at epoch
     */
    function _maxDeposit(Context memory context) private view returns (UFixed6) {
        UFixed6 collateral = UFixed6Lib.from(_collateral(context).max(Fixed6Lib.ZERO));
        return _unhealthy(context) ?
            UFixed6Lib.ZERO :
            maxCollateral.gt(collateral) ?
                maxCollateral.sub(collateral).add(context.global.assets) :
                context.global.assets;
    }

    /**
     * @notice The maximum available redeemable amount at the given epoch for `account`
     * @param context Epoch context to use in calculation
     * @param account Account to calculate redeemable amount
     * @return Maximum available redeemable amount at epoch
     */
    function _maxRedeem(Context memory context, address account) private view returns (UFixed6) {
        return _unhealthy(context) ? UFixed6Lib.ZERO : context.local.shares;
    }

    /**
     * @notice Returns the real amount of collateral in the vault
     * @return value The real amount of collateral in the vault
     **/
    function _collateral(Context memory context) public view returns (Fixed6 value) {
        value = Fixed6Lib.from(_toU6(asset.balanceOf()));
        for (uint256 marketId; marketId < totalMarkets; marketId++)
            value = value.add(context.markets[marketId].collateral);
    }

    function _collateral(Context memory context, uint256 id) public view returns (Fixed6 value) {
        for (uint256 marketId; marketId < totalMarkets; marketId++)
            value = value.add(markets(marketId)
                .market.pendingPositions(address(this), id - _registrations[marketId].initialId).collateral);
        // TODO: should this cap the assets at 0?
    }

    //TODO: replace these with root functions
    function _toU18(UFixed6 n) private pure returns (UFixed18) {
        return UFixed18.wrap(UFixed6.unwrap(n) * 1e12);
    }

    function _toU6(UFixed18 n) private pure returns (UFixed6) {
        return UFixed6.wrap(UFixed18.unwrap(n) / 1e12);
    }
}