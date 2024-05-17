# iQrad V2 - Advanced Loan System

## Overview

iQrad V2 is an advanced, zero-interest, Shariah-compliant loan system designed to facilitate loans and investments in a secure and decentralized manner. The system leverages blockchain technology to offer a transparent and efficient way for users to deposit collateral, take out loans, and for investors to earn returns on their deposits.

## Features

- **Zero Interest Fees**: Complies with Shariah principles by eliminating interest fees.
- **ReentrancyGuard**: Ensures security against reentrancy attacks.
- **Investor Vaults**: Allows investors to deposit USDT and earn returns.
- **Loan System**: Users can take out loans against their iGold collateral.
- **Default Handling**: Automated handling of loan defaults.
- **Testing Mode**: Allows for testing with reduced constraints.
- **SafeERC20**: Uses SafeERC20 for secure token transfers.

## Contracts and Interfaces

### Main Contract

- `iQrad_V2`: The core contract managing loans and investor deposits.

### Interfaces

- `iGoldContract`: Interface for the iGold token contract.
- `IBuyAndBurn`: Interface for the Buy and Burn functionality.
- `IPMMContract`: Interface for the PMM contract used for price quotes.

## Deployment Addresses

- **iGoldContract**: `0x9970CeD626BD512d0C6eF3ac5cc4634f1b417916`
- **IBuyAndBurn**: `0xd73501d9111FF2DE47acBD52D2eAeaaA9e02b4Dd`
- **IPMMContract**: `0x14afbB9E6Ab4Ab761f067fA131e46760125301Fc`
- **Gold Price Feed**: `0x0C466540B2ee1a31b441671eac0ca886e051E410`
- **ISLAMI Token**: `0x9c891326Fd8b1a713974f73bb604677E1E63396D`
- **USDT Token**: `0xc2132D05D31c914a87C6611C10748AEb04B58e8F`

## Functions

### Investor Functions

- `depositAsAngelInvestor(uint256 amount, uint256 _duration)`: Deposit USDT as an angel investor.
- `getInvestorVaults(address investor)`: Get all vaults for a specific investor.
- `isExtendable(address investor, uint256 vaultId)`: Check if a vault's duration can be extended.
- `extendAngelDeposit(uint256 vaultId, uint256 additionalDuration)`: Extend the duration of a deposit.
- `withdrawFromAngelInvestor(uint256 vaultId)`: Withdraw from an angel investor vault.

### User Functions

- `requestLoan(uint256 collateralAmount, LoanTenure tenure)`: Request a loan.
- `makeMonthlyPayment()`: Make a monthly payment.
- `handleDefault(address _user)`: Handle loan default.
- `repayLoan()`: Repay the loan in full.

### Utility Functions

- `getUSDTAmountForLoan(uint256 _collateralAmount)`: Calculate the USDT amount for a given collateral amount.
- `getAvailableUSDTforLoans(LoanTenure tenure)`: Get available USDT for loans based on tenure.
- `calculateOverduePayments(address userAddress)`: Calculate overdue payments and total due amount.
- `getIslamiPrice(uint256 payQuoteAmount)`: Get the price of ISLAMI token.
- `getLatestGoldPriceOunce()`: Get the latest gold price per ounce.
- `getLatestGoldPriceGram()`: Get the latest gold price per gram.
- `getIGoldPrice()`: Get the iGold price.

## Events

- `AngelInvestorDeposited(address indexed investor, uint256 vaultID, uint256 amount)`: Emitted when an investor deposits USDT.
- `AngelInvestorWithdrawn(address indexed investor, uint256 vaultID, uint256 amount)`: Emitted when an investor withdraws USDT.
- `FileOpened(address indexed user)`: Emitted when a user file is opened.
- `CollateralDeposited(address indexed user, uint256 amount)`: Emitted when collateral is deposited.
- `LoanTaken(address indexed user, uint256 amount)`: Emitted when a loan is taken.
- `MonthlyPaymentMade(address indexed user, uint256 amount, uint256 paymentsDue)`: Emitted when a monthly payment is made.
- `LoanDefaulted(address indexed user, uint256 iGoldSold, uint256 paymentAmount, uint256 feePaid, uint256 paymentsDue)`: Emitted when a loan defaults.
- `LoanClosed(address indexed user)`: Emitted when a loan is closed.
- `LoanRepaid(address indexed user)`: Emitted when a loan is repaid.
- `CollateralWithdrawn(address indexed user, uint256 amount)`: Emitted when collateral is withdrawn.
- `AngelInvestorDurationExtended(address indexed investor, uint256 vaultID, uint256 newDuration)`: Emitted when an investor's vault duration is extended.
- `TestingPeriodEnded()`: Emitted when the testing period ends.

## Testing

The contract includes a testing mode with relaxed constraints to facilitate testing. Use the `endTesting()` function to disable the testing mode.

## Security

The contract uses ReentrancyGuard to protect against reentrancy attacks and SafeERC20 for secure token transfers.

## License

This project is licensed under the MIT License.

---

## Developed by Eng. Jaafar Krayem
