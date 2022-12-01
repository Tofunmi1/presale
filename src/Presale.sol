//// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "../lib/openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {AggregatorV3Interface} from
    "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

///crowdsale for $SFP Token
///Soft cap: $50K
///Hard cap: $200K
///Minimum buy: $30
///Maximum buy: $20K

contract Presale is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    mapping(address => uint256) public _contributions;

    IERC20Metadata public _token;

    using SafeERC20 for IERC20Metadata;

    uint256 private _tokenDecimals;
    address payable public _wallet;
    uint256 public _rate;
    uint256 public _weiRaised;
    uint256 public endpresale;
    uint256 public minPurchase;
    uint256 public maxPurchase;
    uint256 public hardCap;
    uint256 public softCap;
    uint256 public availableTokenspresale;
    bool public startRefund = false;
    AggregatorV3Interface internal priceFeed;
    address private priceAddress = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE; // BNB/USD Mainnet

    error zeroRate(uint256);
    error zeroAddress(address _address);
    error AmountIsZero();

    event TokensPurchased(address purchaser, address beneficiary, uint256 value, uint256 amount);
    event Refund(address recipient, uint256 amount);

    modifier presaleActive() {
        require(endpresale > 0 && block.timestamp < endpresale && availableTokenspresale > 0, "presale must be active");
        _;
    }

    modifier presaleNotActive() {
        require(endpresale < block.timestamp, "presale should not be active");
        _;
    }

    constructor(uint256 rate, address payable wallet, address token) {
        if (rate <= 0) revert zeroRate(_rate);
        require(wallet != address(0), "Pre-Sale: wallet is the zero address");
        require(address(token) != address(0), "Pre-Sale: token address is zero");

        _rate = rate;
        _wallet = wallet;
        _token = IERC20Metadata(token);
        _tokenDecimals = IERC20Metadata(address(token)).decimals();
        priceFeed = AggregatorV3Interface(priceAddress);
    }

    receive() external payable {
        if (endpresale > 0 && block.timestamp < endpresale) {
            buyTokens(msg.sender);
        } else {
            endpresale = 0;
            revert("Pre-Sale is closed");
        }
    }

    function fundPresale(uint256 _amount) public {
        _token.safeTransferFrom(msg.sender, address(this), _amount);
        availableTokenspresale += _amount;
    }

    function getBnbPrice() public view returns (uint256) {
        (, int256 price,, uint256 timeStamp,) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return uint256(price);
    }

    //Start Pre-Sale
    function startPresale(
        uint256 endDate,
        uint256 _minPurchase,
        uint256 _maxPurchase,
        uint256 _softCap,
        uint256 _hardCap
    ) external onlyOwner presaleNotActive {
        startRefund = false;
        availableTokenspresale = _token.balanceOf(address(this));
        require(endDate > block.timestamp, "duration should be > 0");
        require(_softCap < _hardCap, "Softcap must be lower than Hardcap");
        require(_minPurchase < _maxPurchase, "minPurchase must be lower than maxPurchase");
        require(availableTokenspresale > 0, "availableTokens must be > 0");
        require(_minPurchase > 0, "_minPurchase should > 0");
        endpresale = endDate;
        minPurchase = _minPurchase;
        maxPurchase = _maxPurchase;
        softCap = _softCap;
        hardCap = _hardCap;
        _weiRaised = 0;
    }

    function stoppresale() external onlyOwner presaleActive {
        endpresale = 0;
        if (_weiRaised >= softCap) {
            _forwardFunds();
        } else {
            startRefund = true;
        }
    }

    //Pre-Sale
    function buyTokens(address beneficiary) public payable nonReentrant presaleActive {
        uint256 weiAmount = msg.value;
        _preValidatePurchase(beneficiary, weiAmount);
        uint256 tokens = _getTokenAmount(weiAmount);
        _weiRaised = _weiRaised.add(weiAmount);
        availableTokenspresale = availableTokenspresale - tokens;
        _contributions[beneficiary] = _contributions[beneficiary].add(weiAmount);
        emit TokensPurchased(msg.sender, beneficiary, weiAmount, tokens);
    }

    function _preValidatePurchase(address beneficiary, uint256 weiAmount) internal view {
        require(beneficiary != address(0), "Crowdsale: beneficiary is the zero address");
        require(weiAmount != 0, "Crowdsale: weiAmount is 0");
        require(weiAmount >= minPurchase, "have to send at least: minPurchase");
        require(_contributions[beneficiary].add(weiAmount) <= maxPurchase, "can\'t buy more than: maxPurchase");
        require((_weiRaised + weiAmount) <= hardCap, "Hard Cap reached");
    }

    function claimTokens() external presaleNotActive {
        require(startRefund == false);
        uint256 tokensAmt = _getTokenAmount(_contributions[msg.sender]);
        _contributions[msg.sender] = 0;
        _token.safeTransfer(msg.sender, tokensAmt);
    }

    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256 _tokenToSend) {
        uint256 bnbPrice = uint256(getBnbPrice() / 10 ** 8);
        uint256 amountSentInUsd = uint256(uint256(weiAmount).div(10 ** 18).mul(bnbPrice));
        require(amountSentInUsd >= minPurchase, "minimum buy not met");
        //$0.015 worth of bnb gets 1 $sfp
        // weiAmount.mul(_rate).div(10 ** _tokenDecimals);
        return uint256(amountSentInUsd).div(_rate).mul(10 ** 18);
    }

    function _forwardFunds() internal {
        _wallet.transfer(msg.value);
    }

    function withdraw() external onlyOwner presaleNotActive {
        require(address(this).balance > 0, "Contract has no money");
        (bool _success,) = address(_wallet).call{value: address(this).balance}("");
        require(_success == true, "withdraw uncessful");
    }

    function checkContribution(address addr) public view returns (uint256) {
        return _contributions[addr];
    }

    function setRate(uint256 newRate) external onlyOwner presaleNotActive {
        _rate = newRate;
    }

    function setAvailableTokens(uint256 amount) public onlyOwner presaleNotActive {
        availableTokenspresale = amount;
    }

    function weiRaised() public view returns (uint256) {
        return _weiRaised;
    }

    function setWalletReceiver(address payable newWallet) external onlyOwner {
        _wallet = newWallet;
    }

    function setHardCap(uint256 value) external onlyOwner {
        hardCap = value;
    }

    function setSoftCap(uint256 value) external onlyOwner {
        softCap = value;
    }

    function setMaxPurchase(uint256 value) external onlyOwner {
        maxPurchase = value;
    }

    function setMinPurchase(uint256 value) external onlyOwner {
        minPurchase = value;
    }

    function withdrawTokens(address tokenAddress) public onlyOwner presaleNotActive {
        IERC20Metadata tokenBEP = IERC20Metadata(tokenAddress);
        uint256 tokenAmt = tokenBEP.balanceOf(address(this));
        require(tokenAmt > 0, "BEP-20 balance is 0");
        tokenBEP.transfer(_wallet, tokenAmt);
    }
}
