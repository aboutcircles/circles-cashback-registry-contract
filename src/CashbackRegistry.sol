// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

contract CashbackRegistry {
    uint96 public immutable START_TIMESTAMP;
    uint96 public immutable DURATION;
    address public immutable DEFAULT_PARTNER;
    bytes32 constant SENTINEL = 0x0000000000000000000000000000000000000000000000000000000000000001;
    mapping(address user => mapping(bytes32 partnerWithPeriod => bytes32 nextPartnerWithPeriod)) partnerChangeLog;
    mapping(address partner => address nextPartner) partnerList;
    mapping(address partner => bool isRegistered) isPartnerREgistered;

    event PartnerRegisteredForPeriod(address indexed user, address indexed partner, uint96 indexed period);
    event NewPartnerRegistered(address partner);

    constructor(uint96 _startTimestamp, uint96 _duration, address _defaultPartner) {
        START_TIMESTAMP = _startTimestamp;
        DURATION = _duration;
        DEFAULT_PARTNER = _defaultPartner;
    }

    function getCurrentPeriod() public view returns (uint96 period) {
        period = (uint96(block.timestamp) - START_TIMESTAMP) / DURATION;
    }

    function getPeriodAtTimestamp(uint256 timestamp) public view returns (uint96 period) {
        period = (uint96(timestamp) - START_TIMESTAMP) / DURATION;
    }

    function getPartnerAtPeriod(address user, uint96 period) public view returns (address partner) {
        bytes32 lastPartnerWithPeriod = partnerChangeLog[user][SENTINEL];

        // In case: period > lastPeriod, loop until we find period <= period in partnerChangeLog
        while (lastPartnerWithPeriod != SENTINEL) {
            address lastPartner;
            uint96 lastPeriod;

            assembly {
                // Extract low 12 bytes (uint96)
                lastPeriod := and(lastPartnerWithPeriod, 0xffffffffffffffffffffffff)

                // Extract high 20 bytes
                lastPartner := shr(96, lastPartnerWithPeriod)
            }

            if (period <= lastPeriod) {
                return lastPartner;
            } else {
                lastPartnerWithPeriod = partnerChangeLog[user][lastPartnerWithPeriod];
            }
        }

        // If no partner is found, return default partner;
        return DEFAULT_PARTNER;
    }

    function getPartnerAtPeriod(address[] memory user, uint96 period) public view returns (address[] memory) {
        address[] memory partners = new address[](user.length);
        for (uint256 i; i < user.length; i++) {
            address partner = getPartnerAtPeriod(user[i], period);
            partners[i] = partner;
        }
        return partners;
    }

    function registerPartner(address partner) external {
        if (partnerList[partner] != address(bytes20(SENTINEL))) {
            address lastPartner = partnerList[address(bytes20(SENTINEL))];
            partnerList[address(bytes20(SENTINEL))] = partner;
            partnerList[partner] = lastPartner;
        }
        emit NewPartnerRegistered(partner);
    }

    function unregisterPartner(address partnerToRemove) external {
        require(partnerToRemove == msg.sender && partnerList[partnerToRemove] != address(bytes20(SENTINEL)));
        address nextPartner = partnerList[partnerToRemove];
        address previousPartner = partnerList[address(bytes20(SENTINEL))];
        // If partnerToRemove is the head
        if (previousPartner == partnerToRemove) {
            partnerList[address(bytes20(SENTINEL))] = nextPartner;
            return;
        }
        while (partnerList[previousPartner] != partnerToRemove) {
            previousPartner = partnerList[previousPartner];
        }
        // Found the previousPartner, point it tot he next partner;
        partnerList[previousPartner] = nextPartner;
    }

    function setPartnerNextPeriod(address partner) external {
        uint96 nextPeriod = getCurrentPeriod() + 1;
        address user = msg.sender;
        // bytes0: bytes19 = partner
        // bytes20: bytes31 = nextPeriod
        bytes32 partnerWithPeriod;
        assembly {
            partnerWithPeriod := shl(partner, 96)
            partnerWithPeriod := and(nextPeriod, 0xffffffffffffffffffffffff)
        }

        bytes32 head = partnerChangeLog[user][SENTINEL];
        if (head == bytes32(0)) {
            // in the case of empty list
            partnerChangeLog[user][SENTINEL] = partnerWithPeriod;
            partnerChangeLog[user][partnerWithPeriod] = SENTINEL;
        } else {
            // find out if this period is the same as head
            uint96 lastPeriod;
            address lastPartner;

            assembly {
                // Extract low 12 bytes (uint96)
                lastPeriod := and(head, 0xffffffffffffffffffffffff)

                // Extract high 20 bytes
                lastPartner := shr(96, head)
            }

            // user in Period X, and wants to update Period {X+1}, but the partner for next period is already set
            // only update the partner address

            if (lastPeriod == nextPeriod && lastPartner != partner) {
                // update in the current head
                partnerChangeLog[user][SENTINEL] = partnerWithPeriod;
            } else {
                // add new  head into linked list if not updated before
                partnerChangeLog[user][SENTINEL] = partnerWithPeriod;
                partnerChangeLog[user][partnerWithPeriod] = head;
            }

            emit PartnerRegisteredForPeriod(user, partner, nextPeriod);
        }
    }
}
