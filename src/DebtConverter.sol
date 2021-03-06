pragma solidity ^0.8.0;

import { IOracle } from "./interfaces/IOracle.sol";
import { ICToken } from "./interfaces/ICToken.sol";
import { ERC20 } from "./interfaces/ERC20.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IFeed } from "./interfaces/IFeed.sol";

contract DebtConverter is ERC20 {
    //Current amount of DOLA-denominated debt accrued by the DebtConverter contract.
    uint public outstandingDebt;

    //Cumulative amount of DOLA-denominated debt accrued by the DebtConverter contract over its lifetime.
    uint public cumDebt;

    //Cumulative amount of DOLA repaid to the DebtConverter contract over its lifetime.
    uint public cumDolaRepaid;

    //Exchange rate of DOLA IOUs to DOLA scaled by 1e18. Default is 1e18.
    //DOLA IOU amount * exchangeRateMantissa / 1e18 = DOLA amount received on redemption
    //Bad Debt $ amount * 1e18 / exchangeRateMantissa = DOLA IOUs received on conversion
    uint public exchangeRateMantissa;

    //The amount that exchangeRateMantissa will increase every second. This is how “interest” is accrued.
    uint public exchangeRateIncreasePerSecond;

    //Timestamp of the last time `accrueInterest()` was called.
    uint public lastAccrueInterestTimestamp;

    //Current repayment epoch
    uint public repaymentEpoch;

    //Cumulative repayments made by addresses other than `owner`
    uint public epochCumRepayments;

    //user address => epoch => Conversion struct
    mapping(address => ConversionData[]) public conversions;
    
    //epoch => Repayment struct
    mapping(uint => RepaymentData) public repayments;

    //user address => bool. True if DOLA IOU transfers to this address are allowed, false by default.
    mapping(address => bool) public transferWhitelist;

    //Can call privileged functions.
    address public owner;

    //Treasury address buying the debt.
    address public treasury;

    //Frontier master oracle.
    IOracle public oracle;

    //DOLA contract
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant anEth = 0x697b4acAa24430F254224eB794d2a85ba1Fa1FB8;
    address public constant anYfi = 0xde2af899040536884e062D3a334F2dD36F34b4a4;
    address public constant anBtc = 0x17786f3813E6bA35343211bd8Fe18EC4de14F28b;

    //Errors
    error TransferToAddressNotWhitelisted();
    error OnlyOwner();
    error InsufficientDebtTokens();
    error InvalidDebtToken();
    error DolaAmountLessThanMinOut();
    error InsufficientDebtToBeRepaid();
    error ConversionDoesNotExist();

    //Events
    event NewOwner(address owner);
    event NewTreasury(address treasury);
    event NewTransferWhitelistAddress(address whitelistedAddr);
    event NewAnnualExchangeRateIncrease(uint increase);
    event Repayment(uint dolaAmount, uint epoch);
    event Redemption(address user, uint dolaAmount);
    event Conversion(address user, uint epoch, address anToken, uint dolaAmount);

    struct RepaymentData {
        uint epoch;
        uint dolaAmount;
        uint dolaRedeemablePerDolaOfDebt;
    }

    struct ConversionData {
        uint lastEpochRedeemed;
        uint dolaAmount;
        uint dolaRedeemed;
    }

    constructor(address _owner, address _treasury, address _oracle) ERC20("DOLA IOU", "DOLAIOU") {
        owner = _owner;
        treasury = _treasury;
        oracle = IOracle(_oracle);
        exchangeRateMantissa = 1e18;
        lastAccrueInterestTimestamp = block.timestamp;
    }

    modifier onlyOwner() {
        if ( msg.sender != owner ) revert OnlyOwner();
        _;
    }

    /*
     * @notice function for converting bad debt anTokens to DOLA IOU tokens.
     * @param anToken Address of the bad debt anToken to be converted
     * @param amount Amount of `token` to be converted. 0 = max
     * @param minOut Minimum DOLA amount worth of DOLA IOUs to be received. Will revert if actual amount is lower.
     */
    function convert(address anToken, uint amount, uint minOut) external {
        if (anToken != anYfi && anToken != anBtc && anToken != anEth) revert InvalidDebtToken();
        uint anTokenBal = IERC20(anToken).balanceOf(msg.sender);
        if (amount == 0) amount = anTokenBal;
        if (anTokenBal < amount) revert InsufficientDebtTokens();

        //Accrue interest so exchange rates are fresh
        accrueInterest();

        //Calculate DOLA/DOLA IOU amounts owed. `underlyingAmount` * underlying price of anToken cancels out decimals
        uint underlyingAmount = ICToken(anToken).balanceOfUnderlying(msg.sender);
        uint _decimals = 28;
        if (anToken == anBtc) {
            _decimals = 18;
        }
        uint dolaValueOfDebt = (oracle.getUnderlyingPrice(anToken) * underlyingAmount) / (10 ** _decimals);
        uint dolaIOUsOwed = convertDolaToDolaIOUs(dolaValueOfDebt);

        if (dolaValueOfDebt < minOut) revert DolaAmountLessThanMinOut();

        outstandingDebt += dolaValueOfDebt;
        cumDebt += dolaValueOfDebt;

        uint epoch = repaymentEpoch;
        ConversionData memory c;
        c.dolaAmount = dolaValueOfDebt;
        c.lastEpochRedeemed = epoch;

        conversions[msg.sender].push(c);

        _mint(msg.sender, dolaIOUsOwed);
        require(IERC20(anToken).transferFrom(msg.sender, treasury, amount), "failed to transfer anTokens");

        emit Conversion(msg.sender, epoch, anToken, dolaValueOfDebt);
    }

    /*
     * @notice function for repaying DOLA to this contract. Callable by anyone.
     * @notice will only move to next epoch if caller is `owner`
     * @param amount Amount of DOLA to repay & transfer to this contract.
     */
    function repayment(uint amount) external {
        uint _outstandingDebt = outstandingDebt;
        if (amount + epochCumRepayments > _outstandingDebt) revert InsufficientDebtToBeRepaid();
        uint _epoch = repaymentEpoch;

        //Only let privileged address add epochs, otherwise this becomes a DoS vector through filling repayments array
        if (msg.sender == owner) {
            //Add all repayments made by others during this epoch to `amount`
            amount += epochCumRepayments;

            //Calculate redeemable DOLA ratio for this epoch
            uint dolaRedeemablePerDolaOfDebt = amount * 99e34 / _outstandingDebt;
            if (_outstandingDebt == 0) {
                dolaRedeemablePerDolaOfDebt = 1e36;
            }

            //Update debt state variables
            outstandingDebt -= amount;
            cumDolaRepaid += amount;

            //Store data from current epoch and update epoch state variables
            repayments[_epoch] = RepaymentData(_epoch, amount, dolaRedeemablePerDolaOfDebt);
            repaymentEpoch += 1;
            epochCumRepayments = 0;
        } else {
            epochCumRepayments += amount;
        }
        
        accrueInterest();
        require(IERC20(DOLA).transferFrom(msg.sender, address(this), amount), "DOLA transfer failed");

        emit Repayment(amount, _epoch);
    }

     /*
     * @notice Function for redeeming DOLA IOUs for DOLA. 
     * @param _conversion index of conversion to redeem for
     * @param _epoch repayment epoch to redeem DOLA from
     */
    function redeem(uint _conversion, uint _epoch) internal returns (uint, uint) {
        uint redeemableDola = getRedeemableDolaFor(msg.sender, _conversion, _epoch);
        uint dolaIOUAmountRequired = convertDolaToDolaIOUs(redeemableDola);

        //If msg.sender does not have enough DOLA IOUs, redeem remainder of their DOLA IOUs
        if (dolaIOUAmountRequired > balanceOf(msg.sender)) {
            dolaIOUAmountRequired = balanceOf(msg.sender);
            redeemableDola = convertDolaIOUsToDola(balanceOf(msg.sender));
        }

        ConversionData storage c = conversions[msg.sender][_conversion];
        c.dolaRedeemed += redeemableDola;

        return (dolaIOUAmountRequired, redeemableDola);
    }

    /*
     * @notice Function wrapper for calling `redeem()`. Will redeem all redeemable epochs for given conversion unless an _endEpoch is provided
     * @param _conversion index of conversion to redeem for
     * @param _endEpoch the last repayment epoch that will be claimed in this call for the given conversion
     */
    function redeemConversion(uint _conversion, uint _endEpoch) external {
        if (_conversion > conversions[msg.sender].length) revert ConversionDoesNotExist();
        ConversionData storage c = conversions[msg.sender][_conversion];
        uint lastEpochRedeemed = c.lastEpochRedeemed;

        uint totalDolaIOUsRequired;
        uint totalDolaRedeemable;

        if (_endEpoch == 0) {
            _endEpoch = repaymentEpoch;
        }

        for (uint i = lastEpochRedeemed; i < _endEpoch;) {
            //Get redeemable DOLA for this epoch and add to running totals
            (uint dolaIOUsRequired, uint dolaRedeemable) = redeem(_conversion, i);
            totalDolaIOUsRequired += dolaIOUsRequired;
            totalDolaRedeemable += dolaRedeemable;

            //We keep the loop going
            unchecked { i++; }
        }

        //After loop breaks: burn DOLA IOUs, transfer DOLA & emit event.
        //This way we don't have to loop these naughty, costly calls
        if (totalDolaRedeemable > 0) {
            c.lastEpochRedeemed = _endEpoch;

            _burn(msg.sender, totalDolaIOUsRequired);
            require(IERC20(DOLA).transfer(msg.sender, totalDolaRedeemable), "DOLA transfer failed");
            
            emit Redemption(msg.sender, totalDolaRedeemable);
        }
    }

    /*
     * @notice function for accounting interest of DOLA IOU tokens. Called by convert(), repayment(), and redeem().
     * @dev only will apply rate increase once per block.
     */
    function accrueInterest() public {
        if(block.timestamp != lastAccrueInterestTimestamp && exchangeRateIncreasePerSecond > 0) {
            uint rateIncrease = (block.timestamp - lastAccrueInterestTimestamp) * exchangeRateIncreasePerSecond;
            exchangeRateMantissa += rateIncrease;
            cumDebt += rateIncrease * totalSupply() / 1e18;
            lastAccrueInterestTimestamp = block.timestamp;
        }
    }

    /*
     * @notice function for calculating redeemable DOLA of an account
     * @param _addr Address to view redeemable DOLA of
     * @param _conversion index of conversion to calculate redeemable DOLA for
     * @param _epoch repayment epoch to calculate redeemable DOLA of
     */
    function getRedeemableDolaFor(address _addr, uint _conversion, uint _epoch) public view returns (uint) {
        ConversionData memory c = conversions[_addr][_conversion];
        uint userRedeemedDola =c.dolaRedeemed;
        uint userConvertedDebt = c.dolaAmount;
        uint dolaRemaining = userConvertedDebt - userRedeemedDola;

        uint totalDolaRedeemable = repayments[_epoch].dolaRedeemablePerDolaOfDebt * userConvertedDebt * exchangeRateMantissa / 1e54;

        if (dolaRemaining >= totalDolaRedeemable) {
            return totalDolaRedeemable;
        } else {
            return dolaRemaining;
        }
    }

    /*
     * @notice function for calculating amount of DOLA equal to a given DOLA IOU amount.
     * @param dolaIOUs DOLA IOU amount to be converted to DOLA
     */
    function convertDolaIOUsToDola(uint dolaIOUs) public view returns (uint) {
        return dolaIOUs * exchangeRateMantissa / 1e18;
    }

    /*
     * @notice function for calculating amount of DOLA IOUs equal to a given DOLA amount.
     * @param dola DOLA amount to be converted to DOLA IOUs
     */
    function convertDolaToDolaIOUs(uint dola) public view returns (uint) {
        return dola * 1e18 / exchangeRateMantissa;
    }

    /*
     * @notice function for calculating amount of DOLA redeemable for an addresses' DOLA IOU balance
     * @param addr Address to return balance of
     */
    function balanceOfDola(address _addr) external view returns (uint) {
        return convertDolaIOUsToDola(balanceOf(_addr));
    }

    // Revert if `to` address is not whitelisted. Transfers between users are not enabled.
    function transfer(address to, uint amount) public override returns (bool) {
        if (!transferWhitelist[to]) revert TransferToAddressNotWhitelisted();

        return super.transfer(to, amount);
    }

    // Revert if `to` address is not whitelisted. Transfers between users are not enabled.
    function transferFrom(address from, address to, uint amount) public override returns (bool) {
        if (!transferWhitelist[to]) revert TransferToAddressNotWhitelisted();

        return super.transferFrom(from, to, amount);
    }

    /*
     * @notice function for transferring `amount` of `token` to the `treasury` address from this contract
     * @param token Address of the token to be transferred out of this contract
     * @param amount Amount of `token` to be transferred out of this contract, 0 = max
     */
    function sweepTokens(address token, uint amount) external onlyOwner {
        if (amount == 0) { 
            require(IERC20(token).transfer(treasury, IERC20(token).balanceOf(address(this))), "Token transfer failed");
        } else {
            require(IERC20(token).transfer(treasury, amount), "Token transfer failed");
        }
    }

    /*
     * @notice function for setting rate at which `exchangeRateMantissa` increases every year
     * @param increasePerYear The amount `exchangeRateMantissa` will increase every year. 1e18 is the default exchange rate.
     */
    function setExchangeRateIncrease(uint increasePerYear) external onlyOwner {
        exchangeRateIncreasePerSecond = increasePerYear / 365 days;
        
        emit NewAnnualExchangeRateIncrease(increasePerYear);
    }

    /*
     * @notice function for setting owner address.
     * @param newOwner Address that will become the new owner of the contract.
     */
    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;

        emit NewOwner(newOwner);
    }

    /*
     * @notice function for setting treasury address.
     * @param newTreasury Address that will be set as the new treasury of the contract.
     */
    function setTreasury(address newTreasury) external onlyOwner {
        treasury = newTreasury;

        emit NewTreasury(newTreasury);
    }

    /*
     * @notice function for whitelisting IOU token transfers to certain addresses.
     * @param whitelistedAddress Address to be added to whitelist. IOU tokens will be able to be transferred to this address.
     */
    function whitelistTransferFor(address whitelistedAddress) external onlyOwner {
        transferWhitelist[whitelistedAddress] = true;

        emit NewTransferWhitelistAddress(whitelistedAddress);
    }
}