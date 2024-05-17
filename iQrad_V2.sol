// SPDX-License-Identifier: MIT

// iQrad V2 with ReentrancyGuard
// Advanced Loan System
// Zero Interest Fees
// Shariah Compliant
// Developer: Jaafar Krayem

pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Interface for interacting with the iGold contract
interface iGoldContract {
    function sell(uint256 _iGoldAmount) external returns(uint256);
    function calculateUSDTReceivedForIGold(uint256 _iGoldAmount) external returns (uint256);
    function calculateIGoldReceivedForUSDT(uint256 _usdtAmount) external  returns (uint256);
    function depositeUSDT(uint256 _amount) external;
}

// Interface for the Buy and Burn mechanism
interface IBuyAndBurn {
    function buyAndBurn(address, uint256) external returns(uint256);
}

// Interface for the PMM contract used for querying prices
interface IPMMContract {
    enum RState {
        ONE,
        ABOVE_ONE,
        BELOW_ONE
    }

    function querySellQuote(address trader, uint256 payQuoteAmount)
        external
        view
        returns (
            uint256 receiveBaseAmount,
            uint256 mtFee,
            RState newRState,
            uint256 newQuoteTarget
        );
}

// Main contract for the iQrad V2 Loan System
contract iQrad_V2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20; // Use SafeERC20 for secure token transfers

    // Publicly accessible contract instances and variables
    IPMMContract public pmmContract = IPMMContract(0x14afbB9E6Ab4Ab761f067fA131e46760125301Fc);
    AggregatorV3Interface public goldPriceFeed = AggregatorV3Interface(0x0C466540B2ee1a31b441671eac0ca886e051E410);

    uint256 public constant oneMonth = 30 days;

    IBuyAndBurn public BAB = IBuyAndBurn(0xd73501d9111FF2DE47acBD52D2eAeaaA9e02b4Dd);
    iGoldContract public iGoldc = iGoldContract(0x9970CeD626BD512d0C6eF3ac5cc4634f1b417916);

    address public deadWallet = 0x000000000000000000000000000000000000dEaD;
    address public islamiToken = 0x9c891326Fd8b1a713974f73bb604677E1E63396D;
    address public iGoldToken = 0x9970CeD626BD512d0C6eF3ac5cc4634f1b417916;
    address public usdtToken = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    address private defaultHandler = 0x1be6cF82aC405cC46D35895262Fa83f582D42884;

    uint256 private fileFee = 1500000; // 1.5 USDT
    uint256 private investorFile = 3000000; // 3 USDT
    
    uint256 public maxVaults = 3;
    uint256 public minLoanAmountDefault = 30 * (1e6);

    uint256 private loanFee = 500000; // 0.5 USDT
    uint256 private lastUsedVaultIndex = 0;
    
    uint256 public loanPercentage = 65;

    uint256 private mp1 = 10;
    uint256 private mp3 = 5;
    uint256 private mp6 = 3;
    uint256 private yp1 = 2;

    uint256 private toBurn = 40; // 40%
    uint256 private toFee = 60; // 60%

    /* Testing Variables */
    bool public isTesting = true;
    uint256 public testingMinLoanAmount = 1 * (1e6); // 1 USDT for testing
    /* Testing Variables */

    uint256 public usdtVault;
    uint256 public usdtInLoans;
    uint256 public iGoldVault;
    uint256 public iGoldSold;
    uint256 public burnedISLAMI;
    
    uint256 public activeLoans;

    address[] public investors;
    address[] public activeLoanUsers;

    uint256 private mUSDT = 1; // multiply by value
    uint256 private dUSDT = 100; // divide by value

    // Enum for Loan Status
    enum LoanStatus {
        NONE,
        ACTIVE,
        DEFAULTED,
        CLOSED
    }
    // Enum for Loan Tenure
    enum LoanTenure {
        NONE,
        ONE_MONTH,
        THREE_MONTHS,
        SIX_MONTHS,
        ONE_YEAR
    }

    // Struct for Angel Investors
    struct AngelInvestor {
        uint256 vault;
        uint256 depositAmount;
        uint256 availableAmount;
        uint256 depositTime;
        uint256 duration;
    }

    // Struct for Investor Vaults
    struct InvestorVaults {
        address investor;
        AngelInvestor[] vaults;
    }

    // Struct for selected vaults during loan allocation
    struct SelectedVault {
        address investorAddress;
        uint256 vaultId;
        uint256 amountAllocated;
    }

    // Struct for vault contributions
    struct VaultContribution {
        address investorAddress;
        uint256 vaultId;
        uint256 availableAmount;
        uint256 contribution;
    }

    // Struct for User information
    struct User {
        bool hasFile;
        uint256 collateral;
        uint256 loanAmount;
        uint256 monthlyPayment;
        uint256 lastPaymentTime;
        uint256 nextPaymentTime;
        LoanStatus status;
        LoanTenure tenure;
        uint256 loanStartDate;
        uint256 paymentsLeft;
    }

    // Struct for User Loan Info
    struct UserLoanInfo {
        address user;
        uint256 collateral;
        uint256 loanAmount;
        uint256 monthlyPayment;
        uint256 paymentsLeft;
        LoanStatus status;
        LoanTenure tenure;
    }

    // Mappings for various data storage
    mapping(address => mapping(uint256 => AngelInvestor)) public angelInvestors;
    mapping(address => uint256) public nextVaultId;
    mapping(address => uint256) public vaultsCount;
    mapping(address => User) public users;
    mapping(address => SelectedVault[]) private selectedVaults;
    mapping(address => bool) public isInvestor;
    mapping(address => bool) public hasLoan;
    mapping(address => bool) public hasInvestorFile;

    // Events for logging actions
    event AngelInvestorDeposited(
        address indexed investor,
        uint256 vaultID,
        uint256 amount
    );
    event AngelInvestorWithdrawn(
        address indexed investor,
        uint256 vaultID,
        uint256 amount
    );
    event FileOpened(address indexed user);
    event CollateralDeposited(address indexed user, uint256 amount);
    event LoanTaken(address indexed user, uint256 amount);
    event MonthlyPaymentMade(address indexed user, uint256 amount, uint256 paymentsDue);
    event LoanDefaulted(address indexed user, uint256 iGoldSold, uint256 paymentAmount, uint256 feePaid, uint256 paymentsDue);
    event LoanClosed(address indexed user);
    event LoanRepaid(address indexed user);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event AngelInvestorDurationExtended(address indexed investor, uint256 vaultID, uint256 newDuration);
    event TestingPeriodEnded();

    // Modifier to check if the user has an open file
    modifier hasFile(address _user) {
        require(users[_user].hasFile, "File not opened");
        _;
    }

    // Modifier to check if the user has an active loan
    modifier hasActiveLoan(address _user) {
        require(users[_user].status == LoanStatus.ACTIVE, "No active loan");
        _;
    }

    // Constructor to initialize the contract owner
    constructor() Ownable(msg.sender) {}

    /* Testing Function */
    function endTesting() external onlyOwner {
        require(isTesting, "Testing period already ended");
        isTesting = false;
        emit TestingPeriodEnded();
    }
    /* Testing Function */

    // Function to edit loan percentage based on tenure
    function editLoanPercentageTenure(uint256 _1m, uint256 _3m, uint256 _6m, uint256 _1y) external onlyOwner {
        mp1 = _1m;
        mp3 = _3m;
        mp6 = _6m;
        yp1 = _1y;
    }

    // Function to edit the maximum number of vaults
    function editMaxVaults(uint256 _max) external onlyOwner {
        require(_max > 0, "At least 1 vault as max");
        maxVaults = _max;
    }

    // Function to edit USDT fee parameters
    function editUSDTFee(uint256 _m, uint256 _d) external onlyOwner {
        require(_m >= 1 && _d > 99, "Multiply equal or over 1 and divide over 99");
        mUSDT = _m;
        dUSDT = _d;
    }

    // Function to approve all tokens for specific contracts
    function approveAll() external {
        IERC20(islamiToken).safeApprove(iGoldToken, type(uint256).max);
        IERC20(usdtToken).safeApprove(iGoldToken, type(uint256).max);
        IERC20(usdtToken).safeApprove(address(BAB), type(uint256).max);
    }

    // Function to set the Buy and Burn contract address
    function setBabContractAddress(address _BAB) external onlyOwner {
        require(_BAB != address(0), "Zero Address");
        BAB = IBuyAndBurn(_BAB);
    }

    // Function to set the burn fee percentages
    function setBurnFee(uint256 _toBurn, uint256 _toFee) external onlyOwner {
        require(_toBurn + _toFee == 100, "Percentage error");
        toBurn = _toBurn;
        toFee = _toFee;
    }

    // Function to get the one-time file opening fee
    function oneTimeFee() public view returns(uint256) {
        return getIslamiPrice(fileFee);
    }

    // Function to get the service fee for loans
    function serviceFee() public view returns(uint256) {
        return getIslamiPrice(loanFee);
    }

    // Function to get the investor fee
    function investorFee() public view returns(uint256) {
        return isTesting ? investorFile / 3 : investorFile;
    }

    // Function to set the ISLAMI token address
    function setISLAMIaddress(address _new) external onlyOwner {
        require(_new != address(0),"Zero address");
        islamiToken = _new;
    }

    // Function to set the iGold token address
    function setiGoldAddress(address _new) external onlyOwner {
        require(_new != address(0),"Zero address");
        iGoldToken = _new;
    }

    /* Start of Investor Functions */

    // Function to deposit as an Angel Investor
    function depositAsAngelInvestor(uint256 amount, uint256 _duration) external nonReentrant {
        if(isTesting) {
            require(amount > testingMinLoanAmount, "Deposit amount must be greater than 0");
        } else {
            require(amount > minLoanAmountDefault, "Deposit amount must be greater than minLoanAmount");
        }
        require(_duration >= 9, "Deposit should be at least for 9 Months");

        if(!hasInvestorFile[msg.sender]) {
            IERC20(usdtToken).safeTransferFrom(msg.sender, address(this), investorFee());
            uint256 fee1 = investorFee() / 3;
            uint256 fee2 = investorFee() - fee1;
            iGoldc.depositeUSDT(fee1);
            burnedISLAMI += BAB.buyAndBurn(usdtToken, fee2);
            hasInvestorFile[msg.sender] = true;
        }

        if(nextVaultId[msg.sender] == 0) {
            nextVaultId[msg.sender] = 1;
        }
        uint256 vaultId = nextVaultId[msg.sender];
        
        IERC20(usdtToken).safeTransferFrom(msg.sender, address(this), amount);

        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];
        investor.depositAmount += amount;
        investor.availableAmount += amount;
        investor.vault = vaultId; // Set the vault ID
        investor.depositTime = block.timestamp; // Set the deposit time
        investor.duration = isTesting ? (_duration * 300) + block.timestamp : (_duration * oneMonth) + block.timestamp;

        usdtVault += amount;
        nextVaultId[msg.sender]++; // Increment the vault ID for the next deposit
        vaultsCount[msg.sender]++;

        if (!isInvestor[msg.sender]) {
            isInvestor[msg.sender] = true;
            investors.push(msg.sender);
        }

        emit AngelInvestorDeposited(msg.sender, vaultId, amount);
    }

    // Function to get the vaults of an investor
    function getInvestorVaults(address investor) external view returns (AngelInvestor[] memory) {
        uint256 vaultCount = nextVaultId[investor];

        // First pass to count non-empty vaults
        uint256 nonEmptyCount = 0;
        for (uint256 i = 1; i < vaultCount; i++) {
            if (angelInvestors[investor][i].depositAmount > 0) {
                nonEmptyCount++;
            }
        }

        // Initialize the array with the size of non-empty vaults
        AngelInvestor[] memory investorVaults = new AngelInvestor[](nonEmptyCount);

        // Second pass to fill the array
        uint256 arrayIndex = 0;
        for (uint256 i = 1; i < vaultCount; i++) {
            if (angelInvestors[investor][i].depositAmount > 0) {
                investorVaults[arrayIndex] = angelInvestors[investor][i];
                arrayIndex++;
            }
        }

        return investorVaults;
    }

    // Function to check if a vault is extendable
    function isExtendable(address investor, uint256 vaultId) public view returns (bool) {
        AngelInvestor memory investorVault = angelInvestors[investor][vaultId];
        // Calculate the remaining duration in seconds
        uint256 remainingDuration = investorVault.duration > block.timestamp ? investorVault.duration - block.timestamp : 0;
        // Convert 6 months to seconds for comparison
        uint256 sixMonths = isTesting ? 6 * 300 : 6 * oneMonth; // Adjust based on whether we're in testing mode
        // Check if the remaining duration is less than 6 months
        return remainingDuration < sixMonths;
    }

    // Function to extend the duration of an Angel Investor deposit
    function extendAngelDeposit(uint256 vaultId, uint256 additionalDuration) external {
        require(vaultId < nextVaultId[msg.sender], "Invalid vault ID");
        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];

        // Calculate the minimum additional duration to extend the deposit to at least 6 months from now
        uint256 remainingDuration = investor.duration > block.timestamp ? investor.duration - block.timestamp : 0;
        uint256 sevenMonths = isTesting ? 7 * 300 : 7 * oneMonth; // Adjust based on whether we're in testing mode
        require(remainingDuration < sevenMonths, "Deposit extension not allowed. More than 6 months remaining.");

        // Ensure the new duration is at least 6 months from now if the remaining duration is less
        if (remainingDuration + (additionalDuration * oneMonth) < sevenMonths) {
            additionalDuration = (sevenMonths - remainingDuration) / oneMonth + 1; // Adjust the additionalDuration to meet the 6 months requirement
        }

        // Extend the duration
        if(isTesting) {
            investor.duration += additionalDuration * 300; // Adjust for testing
        } else {
            investor.duration += additionalDuration * oneMonth; // Adjust for production
        }
        
        emit AngelInvestorDurationExtended(msg.sender, vaultId, investor.duration);
    }

    // Function to withdraw funds from an Angel Investor's vault
    function withdrawFromAngelInvestor(uint256 vaultId) external nonReentrant {
        require(vaultId < nextVaultId[msg.sender], "Invalid vault ID");
        AngelInvestor storage investor = angelInvestors[msg.sender][vaultId];

        uint256 amount = investor.availableAmount;
        require(amount > 0, "No available amount to withdraw");

        // Effects: Update the state before interacting with external contracts
        usdtVault -= amount;
        investor.depositAmount -= amount;
        investor.availableAmount = 0; // Since we're withdrawing all available amount

        if (investor.depositAmount == 0) {
            investor.depositTime = 0;
            investor.vault = 0;
            vaultsCount[msg.sender]--;
            if(vaultsCount[msg.sender] == 0) {
                removeInvestorIfNoVaults(msg.sender);
            }
        }

        // Interaction: Transfer USDT last to adhere to the Checks-Effects-Interactions pattern
        IERC20(usdtToken).safeTransfer(msg.sender, amount);

        emit AngelInvestorWithdrawn(msg.sender, vaultId, amount);
    }

    // Function to fix investor vaults if available amounts exceed deposit amounts
    function fixInvestorVaults() public onlyOwner {
        // Iterate through each investor
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            
            // Iterate through each vault for the investor
            for (uint256 vaultId = 1; vaultId < nextVaultId[investor]; vaultId++) {
                AngelInvestor storage investorVault = angelInvestors[investor][vaultId];
                
                // Check if the available amount exceeds the deposit amount
                if (investorVault.availableAmount > investorVault.depositAmount) {
                    // Fix the available amount to match the deposit amount
                    investorVault.availableAmount = investorVault.depositAmount;
                }
            }
        }
    }

    // Function to fix the USDT vault balance
    function fixUsdtVault() public onlyOwner {
        uint256 totalAvailableInVaults = 0;

        // Iterate through each investor
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            
            // Iterate through each vault for the investor
            for (uint256 vaultId = 1; vaultId < nextVaultId[investor]; vaultId++) {
                AngelInvestor storage investorVault = angelInvestors[investor][vaultId];
                
                // Sum up the available amount in each vault
                totalAvailableInVaults += investorVault.availableAmount;
            }
        }

        // Adjust the usdtVault balance to match the total available in all vaults
        usdtVault = totalAvailableInVaults;

        uint256 excessUSDT = IERC20(usdtToken).balanceOf(address(this)) - usdtVault;
        if(excessUSDT > 0) {
            IERC20(usdtToken).safeTransfer(defaultHandler, excessUSDT);
        }
    }

    /* End of Investor Functions */
    /****************************/

    /* Start of User Functions */

    // Function to request a loan
    function requestLoan(uint256 collateralAmount, LoanTenure tenure) external nonReentrant {
        // Step 1: Open File
        if(!users[msg.sender].hasFile) {
            _openFile(msg.sender);
        }

        // Step 2: Deposit Collateral
        _depositCollateral(msg.sender, collateralAmount);

        // Step 3: Take Loan
        _takeLoan(msg.sender, collateralAmount, tenure);
    }

    // Internal function to open a file for a user
    function _openFile(address user) internal {
        uint256 _oneTimeFee = oneTimeFee();
        IERC20(islamiToken).safeTransferFrom(user, deadWallet, _oneTimeFee);
        users[user].hasFile = true;
        burnedISLAMI += _oneTimeFee;
        emit FileOpened(user);
    }

    // Internal function to deposit collateral
    function _depositCollateral(address user, uint256 amount) internal hasFile(user) {
        IERC20(iGoldToken).safeTransferFrom(user, address(this), amount);
        iGoldVault += amount;
        users[user].collateral += amount;
        emit CollateralDeposited(user, amount);
    }

    // Internal function to take a loan
    function _takeLoan(address user, uint256 collateralAmount, LoanTenure tenure) internal hasFile(user) {
        require(!hasLoan[user],"iQrad: User has loan already");
        uint256 tenureDuration = _getTenureDuration(tenure);
        require(tenureDuration > 0, "Invalid loan tenure");

        users[user].loanStartDate = block.timestamp;

        // Calculate the maximum loan amount as 65% of the collateral value
        uint256 amount = getUSDTAmountForLoan(collateralAmount);

        uint256 minLoanAmount = isTesting ? testingMinLoanAmount : minLoanAmountDefault;
        uint256 maxAmount = getDynamicMaxLoanAmount(tenure);

        require(amount >= minLoanAmount, "iQrad: Loan amount is less than minimum required for the duration");
        require(amount <= maxAmount, "iQrad: Loan amount is more than maximum allowed");

        // Transfer service fee to deadWallet
        IERC20(islamiToken).safeTransferFrom(msg.sender, deadWallet, serviceFee());
        burnedISLAMI += serviceFee();

        require(
            IERC20(usdtToken).balanceOf(address(this)) >= amount,
            "Insufficient USDT in vaults"
        );

        // Select a vault from which to take the loan
        _selectVaultsForLoan(user, amount, tenure);

        uint8 _tenure;
        if (tenure == LoanTenure.ONE_MONTH) {
            _tenure = 1;
        } else if (tenure == LoanTenure.THREE_MONTHS) {
            _tenure = 3;
        } else if (tenure == LoanTenure.SIX_MONTHS) {
            _tenure = 6;
        } else if (tenure == LoanTenure.ONE_YEAR) {
            _tenure = 12;
        }

        uint256 monthlyPayment = amount / _tenure;

        usdtInLoans += amount;
        usdtVault -= amount;

        users[user].loanAmount = amount;
        users[user].monthlyPayment = monthlyPayment;
        users[user].lastPaymentTime = block.timestamp;
        users[user].nextPaymentTime = isTesting ? block.timestamp + 300 : block.timestamp + oneMonth;
        users[user].status = LoanStatus.ACTIVE;
        users[user].tenure = tenure;
        users[user].paymentsLeft = _tenure;

        hasLoan[user] = true;
        activeLoanUsers.push(user);
        activeLoans++;

        emit LoanTaken(user, amount);
        IERC20(usdtToken).safeTransfer(user, amount);
    }

    // Function to get available USDT for loans based on tenure
    function getAvailableUSDTforLoans(LoanTenure tenure) public view returns (uint256, uint256) {
        uint256 tenureDuration = _getTenureDuration(tenure);
        require(tenureDuration > 0, "Invalid loan tenure");

        uint256 totalAvailable = 0;
        uint256 eligibleCount = 0;

        uint256 earliestEndTime = block.timestamp + tenureDuration;

        // Finding eligible vaults and total available amount
        for (uint256 i = 0; i < investors.length; i++) {
            address investorAddress = investors[i];
            for (uint256 vaultId = 1; vaultId < nextVaultId[investorAddress]; vaultId++) {
                AngelInvestor storage vault = angelInvestors[investorAddress][vaultId];
                if (vault.availableAmount > 0 && vault.duration >= earliestEndTime) {
                    totalAvailable += vault.availableAmount;
                    eligibleCount++;
                }
            }
        }
        return (totalAvailable, eligibleCount);
    }

    // Internal function to select vaults for loan allocation
    function _selectVaultsForLoan(address _user, uint256 loanAmount, LoanTenure tenure) internal {
        (uint256 totalAvailable, uint256 eligibleCount) = getAvailableUSDTforLoans(tenure);
        require(totalAvailable >= loanAmount, "Insufficient funds across eligible vaults");
        
        uint256 countToProcess = eligibleCount > maxVaults ? maxVaults : eligibleCount;
        require(countToProcess > 0, "No eligible vaults found");

        delete selectedVaults[_user];  // Clear any existing selected vaults for the user

        uint256 earliestEndTime = block.timestamp + _getTenureDuration(tenure);
        SelectedVault[] memory eligibleVaults = new SelectedVault[](eligibleCount);
        uint256 index = 0;

        // Populate eligible vaults
        for (uint256 i = 0; i < investors.length && index < eligibleCount; i++) {
            address investorAddress = investors[i];
            for (uint256 vaultId = 1; vaultId < nextVaultId[investorAddress]; vaultId++) {
                AngelInvestor storage vault = angelInvestors[investorAddress][vaultId];
                if (vault.availableAmount > 0 && vault.duration >= earliestEndTime) {
                    eligibleVaults[index++] = SelectedVault(investorAddress, vaultId, vault.availableAmount);
                }
            }
        }

        // Shuffle eligible vaults for fairness in fund distribution
        for (uint256 i = 0; i < index; i++) {
            uint256 n = i + (uint256(keccak256(abi.encodePacked(block.timestamp))) % (index - i));
            SelectedVault memory temp = eligibleVaults[n];
            eligibleVaults[n] = eligibleVaults[i];
            eligibleVaults[i] = temp;
        }

        // Allocate funds to selected vaults
        uint256 remainingAmount = loanAmount;
        for (uint256 i = 0; i < countToProcess; i++) {
            if (remainingAmount == 0) break;

            uint256 allocation = (remainingAmount * eligibleVaults[i].amountAllocated) / totalAvailable;

            if (i == countToProcess - 1 || allocation > eligibleVaults[i].amountAllocated) {
                allocation = eligibleVaults[i].amountAllocated;
            }

            if (allocation > remainingAmount) {
                allocation = remainingAmount;
            }

            angelInvestors[eligibleVaults[i].investorAddress][eligibleVaults[i].vaultId].availableAmount -= allocation;
            selectedVaults[_user].push(SelectedVault(eligibleVaults[i].investorAddress, eligibleVaults[i].vaultId, allocation));
            remainingAmount -= allocation;
        }

        require(remainingAmount == 0, "Loan amount not fully allocated");  // Verify the entire loan amount is allocated
    }

    // Utility function to get the minimum of two values
    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // Function to get the USDT amount for a given collateral amount
    function getUSDTAmountForLoan(uint256 _collateralAmount) public view returns (uint256 loanAmount) {
        // Calculate the total value of the iGold collateral
        uint256 collateralValue = (_collateralAmount * uint256(getIGoldPrice())) / (1e8);

        // Calculate the maximum loan amount as 65% of the collateral value
        uint256 amount = ((collateralValue * loanPercentage) / 100) / (1e2);
        uint256 onePercentFees = amount / 100;
        uint256 actualReturnAmount = amount - onePercentFees;

        return actualReturnAmount;
    }

    // Internal function to get the tenure duration in seconds
    function _getTenureDuration(LoanTenure tenure) internal view returns (uint256) {
        return _calculateNormalDuration(tenure);
    }

    // Private function to calculate the normal duration for a given tenure
    function _calculateNormalDuration(LoanTenure tenure) private view returns (uint256) {
        if (tenure == LoanTenure.ONE_MONTH) {
            return isTesting ? 5 * 60 : oneMonth;
        } else if (tenure == LoanTenure.THREE_MONTHS) {
            return isTesting ? 15 * 60 : 90 days;
        } else if (tenure == LoanTenure.SIX_MONTHS) {
            return isTesting ? 30 * 60 : 180 days;
        } else if (tenure == LoanTenure.ONE_YEAR) {
            return isTesting ? 60 * 60 : 365 days;
        } else {
            revert("Invalid loan tenure");
        }
    }

    // Function to make a monthly payment
    function makeMonthlyPayment() external nonReentrant hasActiveLoan(msg.sender) {
        User storage user = users[msg.sender];
        (uint256 overduePayments, uint256 totalDue) = calculateOverduePayments(msg.sender);
        // Adjustments for scenarios where overduePayments or totalDue might be zero
        overduePayments = overduePayments == 0 ? 1 : overduePayments;
        totalDue = totalDue == 0 ? user.monthlyPayment : totalDue;

        // Ensure the user has sufficient balance for the payment.
        require(IERC20(usdtToken).balanceOf(msg.sender) >= totalDue, "Insufficient balance for payment");
        
        // Check if Last Payment
        if (user.paymentsLeft == overduePayments) {
            _repayLoan(msg.sender);
        } else {
            // Proceed with the normal payment process for overdue payments.
            IERC20(usdtToken).safeTransferFrom(msg.sender, address(this), totalDue);
            // Update the state to reflect the payment
            usdtInLoans -= totalDue;
            usdtVault += totalDue;
            user.lastPaymentTime = block.timestamp;
            user.loanAmount -= totalDue;
            user.paymentsLeft -= overduePayments;

            updateNextPaymentTime(msg.sender);

            emit MonthlyPaymentMade(msg.sender, users[msg.sender].monthlyPayment, overduePayments);

            for (uint256 i = 0; i < overduePayments; i++) {
                _updateVaults(msg.sender); // Update vaults for each overdue payment.
            }
        }
    }

    // Internal function to calculate default parameters
    function _toDefault(address _user) internal view returns (uint256, uint256, uint256) {
        // Get the current price of iGold in terms of USDT
        uint256 _iGoldPrice = uint256(getIGoldPrice() / (1e2));
        require(_iGoldPrice > 0, "Invalid iGold price");

        (uint256 overduePayments, uint256 totalDue) = calculateOverduePayments(_user);
        uint256 defaultFee = totalDue / 100; // 1% of the user monthly payment
        uint256 defaultPayment = totalDue + defaultFee;
        uint256 iGoldFee = (defaultPayment * mUSDT / dUSDT) * 2;
        uint256 finalAmount = defaultPayment + iGoldFee;
        return (overduePayments, totalDue, finalAmount);
    }

    // Function to handle loan defaults
    function handleDefault(address _user) public nonReentrant hasActiveLoan(_user) {
        User storage user = users[_user];

        // Calculate the end of the grace period
        uint256 gracePeriodEnd = user.nextPaymentTime + (isTesting ? 1 minutes : 5 days);
        require(block.timestamp >= gracePeriodEnd, "Within grace period");

        (uint256 overduePayments, uint256 totalDue, uint256 finalAmount) = _toDefault(_user);
        uint256 totaliGoldToSell = iGoldc.calculateIGoldReceivedForUSDT(finalAmount);

        if (user.collateral < totaliGoldToSell) {
            totaliGoldToSell = user.collateral;
        }

        if (user.paymentsLeft == overduePayments) {
            totalDue = user.loanAmount;
        }

        uint256 usdtReceived = iGoldc.sell(totaliGoldToSell);
        uint256 actualUsdtReceived = usdtReceived - (usdtReceived * mUSDT / dUSDT);

        require(actualUsdtReceived >= totalDue, "USDT received is less than the monthly fee");

        uint256 excessUSDT = actualUsdtReceived - totalDue;

        iGoldVault -= totaliGoldToSell;
        usdtVault += totalDue;
        usdtInLoans -= totalDue;
        user.collateral -= totaliGoldToSell;
        user.paymentsLeft -= overduePayments;

        if (excessUSDT > 0) {
            IERC20(usdtToken).safeTransfer(defaultHandler, excessUSDT);
        }

        if (user.loanAmount == totalDue) {
            user.loanAmount = 0; // Consider the loan fully repaid if within tolerance
            repayInvestors(_user);
        } else {
            user.loanAmount -= totalDue;
            for (uint256 i = 0; i < overduePayments; i++) {
                _updateVaults(_user); // Adjust the vaults for each overdue payment.
            }
            user.lastPaymentTime = block.timestamp;
            updateNextPaymentTime(_user);
        }

        emit LoanDefaulted(_user, totaliGoldToSell, totalDue, excessUSDT, overduePayments);
    }

    // Internal function to update the next payment time for a user
    function updateNextPaymentTime(address _user) private {
        User storage user = users[_user];
        // Calculate the next payment time based on the current date and payment frequency
        uint256 monthsSinceStart = (block.timestamp - user.loanStartDate) / oneMonth;
        user.nextPaymentTime = isTesting ? block.timestamp + 300 : user.loanStartDate + ((monthsSinceStart + 1) * oneMonth);
    }

    // Internal function to repay investors after loan repayment
    function repayInvestors(address _user) private {
        SelectedVault[] storage vaults = selectedVaults[_user];
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 allocation = vaults[i].amountAllocated;
            angelInvestors[vaults[i].investorAddress][vaults[i].vaultId].availableAmount += allocation;
            vaults[i].amountAllocated -= allocation;
        }
        closeLoan(_user);
    }

    // Internal function to update vaults for each overdue payment
    function _updateVaults(address _user) private {
        User storage user = users[_user];
        SelectedVault[] storage vaults = selectedVaults[_user];
        uint256 monthlyPayment = user.monthlyPayment;

        uint256 totalAllocated = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            totalAllocated += vaults[i].amountAllocated;
        }

        uint256 totalDistributedPayment = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            if (totalAllocated == 0) continue; // Prevent division by zero

            // Calculate payment for this vault based on its share of the total allocation
            uint256 paymentForThisVault = (vaults[i].amountAllocated * monthlyPayment) / totalAllocated;

            // If it's the last vault, adjust to account for any rounding errors
            if (i == vaults.length - 1) {
                paymentForThisVault = monthlyPayment - totalDistributedPayment;
            }

            // Update the allocated amount for the loan in each vault
            if (vaults[i].amountAllocated >= paymentForThisVault) {
                vaults[i].amountAllocated -= paymentForThisVault;
                totalDistributedPayment += paymentForThisVault;
            } else {
                // If the vault allocation is less than the payment, adjust to what's left
                paymentForThisVault = vaults[i].amountAllocated;
                vaults[i].amountAllocated = 0;
                totalDistributedPayment += paymentForThisVault;
            }

            // Update the available amount for the angel investor's vault
            AngelInvestor storage investorVault = angelInvestors[vaults[i].investorAddress][vaults[i].vaultId];
            uint256 newAvailableAmount = investorVault.availableAmount + paymentForThisVault;

            // Ensure the new available amount does not exceed the initial deposit amount
            if (newAvailableAmount > investorVault.depositAmount) {
                newAvailableAmount = investorVault.depositAmount;
            }

            // Update the investor vault's available amount
            investorVault.availableAmount = newAvailableAmount;
        }
    }

    // Internal function to close a loan
    function closeLoan(address _user) internal hasActiveLoan(_user) {
        User storage user = users[_user];

        // Check if the entire loan amount has been repaid
        require(
            user.loanAmount == 0,
            "Loan amount must be fully repaid to close the loan"
        );

        // Calculate the remaining collateral to be returned
        uint256 remainingCollateral = user.collateral;

        // Transfer the remaining collateral back to the user
        IERC20(iGoldToken).safeTransfer(_user, remainingCollateral);

        iGoldVault -= remainingCollateral;

        // Update the user's loan status to CLOSED
        user.status = LoanStatus.CLOSED;

        // Reset other loan-related variables
        user.collateral = 0;
        user.loanAmount = 0;
        user.monthlyPayment = 0;
        user.lastPaymentTime = 0;
        user.nextPaymentTime = 0;
        user.tenure = LoanTenure.NONE;
        user.loanStartDate = 0;

        hasLoan[_user] = false;
        _removeActiveLoanUser(_user);
        activeLoans--;

        emit LoanClosed(_user);
    }

    // Function to repay a loan
    function repayLoan() public nonReentrant hasActiveLoan(msg.sender) {
        _repayLoan(msg.sender);
    }

    // Internal function to repay a loan
    function _repayLoan(address _user) private {
        User storage user = users[_user];
        uint256 remainingLoan = user.loanAmount;
        IERC20(usdtToken).safeTransferFrom(
            _user,
            address(this),
            remainingLoan
        );

        // Update investors vaults
        SelectedVault[] storage vaults = selectedVaults[_user];
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 allocation = vaults[i].amountAllocated;
            angelInvestors[vaults[i].investorAddress][vaults[i].vaultId].availableAmount += allocation;
            vaults[i].amountAllocated -= allocation;
        }
        usdtVault += remainingLoan;

        user.loanAmount = 0;
        user.status = LoanStatus.CLOSED;

        // Transfer back the collateral to the user
        uint256 collateral = user.collateral;
        IERC20(iGoldToken).safeTransfer(_user, collateral);

        iGoldVault -= collateral;
        usdtInLoans -= remainingLoan;
        user.collateral = 0;
        user.monthlyPayment = 0;
        user.lastPaymentTime = 0;
        user.nextPaymentTime = 0;
        user.tenure = LoanTenure.NONE;
        user.loanStartDate = 0;
        user.paymentsLeft = 0;

        hasLoan[_user] = false;
        _removeActiveLoanUser(_user);
        activeLoans--;

        emit LoanRepaid(_user);
    }

    // Function to update the file fee
    function updateFileFee(uint256 newFee) external onlyOwner {
        fileFee = newFee;
    }

    // Function to update the investor fee
    function updateInvestorFee(uint256 newFee) external onlyOwner {
        investorFile = newFee;
    }

    // Function to get the iGold balance of a user
    function iGoldBalance(address _user) public view returns (uint256 _balance) {
        _balance = IERC20(iGoldToken).balanceOf(address(_user));
        return _balance;
    }

    // Function to get the ISLAMI balance of a user
    function ISLAMIbalance(address _user) public view returns (uint256 _balance) {
        _balance = IERC20(islamiToken).balanceOf(address(_user));
        return _balance;
    }

    // Function to get the USDT balance of a user
    function usdtBalance(address _user) public view returns (uint256 _balance) {
        _balance = IERC20(usdtToken).balanceOf(address(_user));
        return _balance;
    }

    // Function to set the loan fee
    function setLoanFee(uint256 _newLoanFee) external onlyOwner {
        require(_newLoanFee > 0, "Loan fee must be greater than zero");
        loanFee = _newLoanFee;
    }

    // Function to set the minimum loan amounts
    function setMinLoanAmounts(uint256 _default) external onlyOwner {
        minLoanAmountDefault = _default * (1e6);
    }

    // Function to get all investors' vaults
    function getAllInvestorsVaults() external view returns (InvestorVaults[] memory) {
        InvestorVaults[] memory allInvestorVaults = new InvestorVaults[](investors.length);

        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 _vaultsCount = nextVaultId[investor] - 1; // Assuming nextVaultId points to the next available ID

            // First, count the non-zero vaults for the current investor
            uint256 nonZeroVaultCount = 0;
            for (uint256 j = 1; j <= _vaultsCount; j++) {
                if (angelInvestors[investor][j].depositAmount > 0) {
                    nonZeroVaultCount++;
                }
            }

            // Then, allocate memory for the vaults array based on the count of non-zero vaults
            AngelInvestor[] memory nonZeroVaults = new AngelInvestor[](nonZeroVaultCount);
            uint256 nonZeroIndex = 0; // Use a separate index for the non-zero vaults array
            for (uint256 j = 1; j <= _vaultsCount; j++) {
                if (angelInvestors[investor][j].depositAmount > 0) {
                    nonZeroVaults[nonZeroIndex++] = angelInvestors[investor][j];
                }
            }

            allInvestorVaults[i] = InvestorVaults({
                investor: investor,
                vaults: nonZeroVaults
            });
        }

        return allInvestorVaults;
    }

    // Function to get the dynamic maximum loan amount based on tenure
    function getDynamicMaxLoanAmount(LoanTenure tenure) public view returns (uint256) {
        (uint256 averageDeposit,) = getAvailableUSDTforLoans(tenure);
        
        if (tenure == LoanTenure.ONE_MONTH) {
            return averageDeposit * mp1 / 100; // 10% of average deposit
        } else if (tenure == LoanTenure.THREE_MONTHS) {
            return averageDeposit * mp3 / 100; // 5% of average deposit
        } else if (tenure == LoanTenure.SIX_MONTHS) {
            return averageDeposit * mp6 / 100; // 3% of average deposit
        } else if (tenure == LoanTenure.ONE_YEAR) {
            return averageDeposit * yp1 / 100; // 2% of average deposit
        } else {
            return 0; // For tenure NONE or any undefined tenure
        }
    }

    // Internal function to remove an investor if no vaults are present
    function removeInvestorIfNoVaults(address investor) internal {
        if (vaultsCount[investor] == 0) { // Assuming 0 or 1 indicates no active vaults
            // Find the investor in the investors array
            for (uint256 i = 0; i < investors.length; i++) {
                if (investors[i] == investor) {
                    // Swap with the last element and remove the last element
                    investors[i] = investors[investors.length - 1];
                    investors.pop();
                    nextVaultId[investor] = 0;
                    isInvestor[investor] = false;
                    break;
                }
            }
        }
    }

    // Internal function to remove an active loan user
    function _removeActiveLoanUser(address user) private {
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            if (activeLoanUsers[i] == user) {
                activeLoanUsers[i] = activeLoanUsers[activeLoanUsers.length - 1];
                activeLoanUsers.pop();
                break;
            }
        }
    }

    // Function to check and handle all defaults
    function checkAndHandleAllDefaults() external {
        // Iterate over the array of users with active loans
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            address user = activeLoanUsers[i];
            if (block.timestamp >= users[user].nextPaymentTime && users[user].status == LoanStatus.ACTIVE) {
                handleDefault(user);
            }
        }
    }

    // Function to check if there are any defaults
    function checkAllDefaults() public view returns (bool areDefaults) {
        // Iterate over the array of users with active loans
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            address user = activeLoanUsers[i];
            if (block.timestamp >= users[user].nextPaymentTime && users[user].status == LoanStatus.ACTIVE) {
                return true;
            }
        }
    }

    // Function to check if any payment is due for a given user address
    function isAnyPaymentDue(address userAddress) public view returns (bool) {
        // Check if the user has an active loan
        if (users[userAddress].status != LoanStatus.ACTIVE) {
            return false; // No active loan, so no payment is due
        }

        // Check if the next payment time is past the current block timestamp
        if (block.timestamp >= users[userAddress].nextPaymentTime) {
            return true; // Payment is due
        }

        return false; // No payment is due
    }

    // Function to get the price of ISLAMI token
    function getIslamiPrice(uint256 payQuoteAmount) public view returns (uint256 _price) {
        address trader = address(this);
        // Call the querySellQuote function from the PMMContract
        (uint256 receiveBaseAmount, , , ) = pmmContract.querySellQuote(
            trader,
            payQuoteAmount
        );
        _price = receiveBaseAmount;
        return _price;
    }

    // Function to get the latest gold price per ounce
    function getLatestGoldPriceOunce() public view returns (int256) {
        (, int256 pricePerOunce, , , ) = goldPriceFeed.latestRoundData();
        return pricePerOunce;
    }

    // Function to get the latest gold price per gram
    function getLatestGoldPriceGram() public view returns (int256) {
        int256 pricePerGram = (getLatestGoldPriceOunce() * 1e8) / 3110347680; // Multiplied by 10^8 to handle decimals

        return pricePerGram;
    }

    // Function to get the iGold price
    function getIGoldPrice() public view returns (int256) {
        int256 _iGoldPrice = (getLatestGoldPriceGram()) / 10;
        return _iGoldPrice;
    }

    // Function to set the PMM contract address
    function setPMMContract(address _newPMMContract) external onlyOwner {
        require(_newPMMContract != address(0), "Invalid address.");
        pmmContract = IPMMContract(_newPMMContract);
    }

    // Function to set the gold price feed address
    function setGoldPriceFeed(address _newGoldPriceFeed) external onlyOwner {
        require(_newGoldPriceFeed != address(0), "Invalid address.");
        goldPriceFeed = AggregatorV3Interface(_newGoldPriceFeed);
    }

    // Function to set the loan percentage
    function setLoanPercentage(uint256 _percentage) external onlyOwner {
        require(_percentage >= 50 && _percentage <= 70, "Can't set percentage lower than 50 or higher than 70");
        loanPercentage = _percentage;
    }

    // Function to calculate overdue payments and total due amount
    function calculateOverduePayments(address userAddress) public view returns (uint256 overduePayments, uint256 totalDue) {
        User storage user = users[userAddress];
        if (user.status != LoanStatus.ACTIVE) {
            return (0, 0);
        }

        uint256 paymentInterval = isTesting ? 300 : oneMonth;
        uint256 paymentsSinceStart = (block.timestamp - user.loanStartDate) / paymentInterval;
        uint256 paymentsMade = (user.lastPaymentTime - user.loanStartDate) / paymentInterval;

        overduePayments = paymentsSinceStart - paymentsMade;
        if (overduePayments > user.paymentsLeft) {
            overduePayments = user.paymentsLeft;
        }
        totalDue = overduePayments * user.monthlyPayment;
        return (overduePayments, totalDue);
    }

    // Function to get all users' loans
    function getAllUsersLoans() public view returns (UserLoanInfo[] memory) {
        UserLoanInfo[] memory loans = new UserLoanInfo[](activeLoanUsers.length);
        for (uint256 i = 0; i < activeLoanUsers.length; i++) {
            address userAddress = activeLoanUsers[i];
            User storage user = users[userAddress];
            loans[i] = UserLoanInfo({
                user: userAddress,
                collateral: user.collateral,
                loanAmount: user.loanAmount,
                monthlyPayment: user.monthlyPayment,
                paymentsLeft: user.paymentsLeft,
                status: user.status,
                tenure: user.tenure
            });
        }
        return loans;
    }

    // Function to get selected vaults for a user's loan
    function getSelectedVaults(address _user) public view returns (SelectedVault[] memory) {
        return selectedVaults[_user];
    }

    // Function to get the grace period for a user
    function getGracePeriod(address _user) public view returns (uint256) {
        User storage user = users[_user];
        // Calculate the end of the grace period
        return user.nextPaymentTime + (isTesting ? 1 minutes : 5 days);
    }

    // Function to clear any dirt tokens in the contract
    function clearDirt(address _token) external onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(deadWallet, amount);
    }
}

                /*********************************************************
                       Developed by Eng. Jaafar Krayem Copyright 2024
                **********************************************************/
