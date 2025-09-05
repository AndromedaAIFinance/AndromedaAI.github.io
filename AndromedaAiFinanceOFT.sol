// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title AndromedaAiFinanceOFT
/// @notice A LayerZero OFT V2 cross-chain token with 25bps tax on DEX swaps.
/// @dev Assumptions:
///      - Tax is always 25bps (0.25%) and immutable.
///      - Tax is rounded up to ensure minimum collection.
///      - Treasury wallet is immutable and trusted.
///      - Only router-initiated swaps are subject to tax.
contract AndromedaAiFinanceOFT is Ownable, OFT, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NotRouter();
    error TransferFailed();
    error InsufficientAllowance();

    /// @notice Treasury wallet for collected 25bps tax. Immutable.
    address private immutable treasuryWallet = 0x6bC8Ca22BE1a7F658EcDD85C9C64A2323465f912;
    /// @notice Immutable 25bps (0.25%) tax rate.
    uint256 private constant TAX_RATE = 25;
    /// @notice Immutable hard cap: 299,792,458 tokens (18 decimals).
    uint256 private constant HARD_CAP_SUPPLY = 299792458 * 10 ** 18;
    /// @notice Flag indicating if this is the home chain where tokens are originally minted.
    bool public immutable isHomeChain;

    /// @notice Tracks if 25bps tax is paused.
    bool private _taxPaused = true;
    /// @notice DEX router addresses subject to 25bps tax.
    mapping(address => bool) private _routerAddresses;

    /// @notice Emitted when 25bps tax is collected from a DEX swap.
    event TaxCollected(address indexed from, uint256 amount);
    /// @notice Emitted when 25bps tax collection is paused or unpaused.
    event TaxPaused(bool paused);
    /// @notice Emitted when a router address is added to the taxable list.
    event RouterAddressAdded(address router);
    /// @notice Emitted when a router address is removed from the taxable list.
    event RouterAddressRemoved(address router);

    /// @notice Initializes token with 25bps tax, treasury, and mints full hard cap to owner.
    /// @dev The total supply is fixed at 299,792,458 tokens (18 decimals) and cannot be changed.
    /// @param _name Token name.
    /// @param _symbol Token symbol.
    /// @param _lzEndpoint LayerZero endpoint for cross-chain functionality.
    /// @param _owner Initial owner.
    /// @param _isHomeChain Set to true only for the primary chain where tokens are minted.
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _owner,
        bool _isHomeChain
    ) OFT(_name, _symbol, _lzEndpoint, _owner) Ownable(_owner) {
        isHomeChain = _isHomeChain;

        // Mint full hard cap to owner on deployment only if this is the home chain
        if (isHomeChain) {
            _mint(_owner, HARD_CAP_SUPPLY);
        }
    }

    /// @notice Applies 25bps tax on DEX router-initiated swaps.
    /// @dev Tax only if: transaction initiated by router, tax not paused, neither sender nor recipient is treasury.
    function _transferWithTax(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        if (sender == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert TransferFailed();

        // Tax applies if:
        // 1. Tax is not paused
        // 2. Transaction is initiated by a router (msg.sender is router)
        // 3. Neither sender nor recipient is the treasury (to avoid double-taxing)
        bool isRouterSwap = _routerAddresses[msg.sender];
        bool shouldTax = !_taxPaused &&
                         isRouterSwap &&
                         sender != treasuryWallet &&
                         recipient != treasuryWallet;

        uint256 transferAmount;
        uint256 taxAmount;

        if (shouldTax) {
            require(amount >= 1e11, "Swap too small"); // Minimum swap amount: 0.0000001 tokens (1e11 wei)

            taxAmount = (amount >= 400) ? (amount * TAX_RATE) / 10_000 : 1;
            unchecked {
                // Safe: taxAmount is always <= amount
                transferAmount = amount - taxAmount;
            }
        } else {
            transferAmount = amount;
        }

        super._transfer(sender, recipient, transferAmount);

        if (shouldTax) {
            super._transfer(sender, treasuryWallet, taxAmount);
            emit TaxCollected(sender, taxAmount);
        }
    }

    /// @notice Transfers tokens, applying 25bps tax if transaction is router-initiated.
    function transfer(address recipient, uint256 amount) public override nonReentrant returns (bool) {
        _transferWithTax(msg.sender, recipient, amount);
        return true;
    }

    /// @notice Transfers tokens from sender to recipient, applying 25bps tax if transaction is router-initiated.
    function transferFrom(address sender, address recipient, uint256 amount) public override nonReentrant returns (bool) {
        uint256 currentAllowance = allowance(sender, _msgSender());
        if (currentAllowance < amount) revert InsufficientAllowance();

        _approve(sender, _msgSender(), currentAllowance - amount);
        _transferWithTax(sender, recipient, amount);
        return true;
    }

    /// @notice Pauses/unpauses 25bps tax on DEX swaps.
    function setTaxPaused(bool paused) external onlyOwner {
        _taxPaused = paused;
        emit TaxPaused(paused);
    }

    /// @notice Adds router address to 25bps tax list.
    function addRouterAddress(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        _routerAddresses[router] = true;
        emit RouterAddressAdded(router);
    }

    /// @notice Removes router address from 25bps tax list.
    function removeRouterAddress(address router) external onlyOwner {
        if (!_routerAddresses[router]) revert NotRouter();
        _routerAddresses[router] = false;
        emit RouterAddressRemoved(router);
    }

    /// @notice Returns if 25bps tax is paused.
    function isTaxPaused() external view returns (bool) {
        return _taxPaused;
    }

    /// @notice Returns if address is a router (subject to 25bps tax).
    function isRouter(address addr) external view returns (bool) {
        return _routerAddresses[addr];
    }

    /// @notice Returns 25bps (0.25%) tax rate.
    function getTaxRate() external pure returns (uint256) {
        return TAX_RATE;
    }

    /// @notice Returns the treasury wallet address.
    function getTreasuryWallet() external view returns (address) {
        return treasuryWallet;
    }
}
