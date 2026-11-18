// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.28;

import {IPriceSource} from "../../interfaces/IPriceSource.sol";

/// @notice A price source for a trial market on the test network: a settable price that can also be
///         made to revert or to answer with malformed data. A copy of the test mock, kept here so
///         that `src/` holds no mock. Never for a live network.
contract TrialPriceSource is IPriceSource {
    uint256 internal _price;
    bool public reverting;
    bool public malformed;

    constructor(uint256 price_) {
        _price = price_;
    }

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function setReverting(bool value) external {
        reverting = value;
    }

    function setMalformed(bool value) external {
        malformed = value;
    }

    function price() external view returns (uint256) {
        if (reverting) revert("price source down");
        if (malformed) {
            assembly {
                return(0, 1)
            }
        }
        return _price;
    }
}
