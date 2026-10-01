// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDmdSwapCallee} from "../../src/interfaces/IDmdSwapCallee.sol";
import {IDmdSwapPair} from "../../src/interfaces/IDmdSwapPair.sol";
import {DmdSwapPair} from "../../src/core/DmdSwapPair.sol";
import {DmdSwapFactory} from "../../src/core/DmdSwapFactory.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns 1% of every transfer (classic fee-on-transfer token).
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Token that tries to re-enter a target during transfers (ERC777-style hook simulation).
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public reentrySucceeded;

    constructor() ERC20("Reentrant", "RENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && !attempted && from != address(0)) {
            attempted = true;
            (reentrySucceeded,) = target.call(payload);
        }
    }
}

/// @dev Flash-swap borrower. mode 0: repay correctly; 1: repay nothing; 2: repay without fee;
///      3: try to read getReserves mid-swap; 4: try to re-enter the pair.
contract FlashBorrower is IDmdSwapCallee {
    uint256 public mode;
    bool public getReservesReverted;
    bool public reentryReverted;

    function setMode(uint256 m) external {
        mode = m;
    }

    function borrow(address pair, uint256 amount0Out, uint256 amount1Out) external {
        IDmdSwapPair(pair).swap(amount0Out, amount1Out, address(this), hex"01");
    }

    function dmdSwapCall(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        IDmdSwapPair pair = IDmdSwapPair(msg.sender);
        address token = amount0 > 0 ? pair.token0() : pair.token1();
        uint256 amount = amount0 > 0 ? amount0 : amount1;
        if (mode == 3) {
            try pair.getReserves() {} catch { getReservesReverted = true; }
        }
        if (mode == 4) {
            try pair.sync() {} catch { reentryReverted = true; }
        }
        if (mode == 0 || mode == 3 || mode == 4) {
            // repay amount / (1 - fee) rounded up: amount*10000/(10000-30) + 1
            uint256 repay = (amount * 10_000) / (10_000 - 30) + 1;
            IERC20(token).transfer(msg.sender, repay);
        } else if (mode == 2) {
            IERC20(token).transfer(msg.sender, amount);
        }
    }
}

contract RejectDMD {
    receive() external payable {
        revert("no");
    }
}

/// @dev Upgrade target for the pair beacon: same storage, adds version().
contract DmdSwapPairV2 is DmdSwapPair {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Upgrade target for the factory.
contract DmdSwapFactoryV2 is DmdSwapFactory {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Token that reverts transfers to blocked recipients (USDT/USDC-style blacklist).
contract BlacklistToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blacklist", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}
