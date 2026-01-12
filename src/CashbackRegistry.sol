// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

contract CashbackRegistry {
    uint96 public immutable START_TIMESTAMP;
    uint96 public immutable DURATION;
    bytes32 constant SENTINEL_32 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    address constant SENTINEL_20 = 0x0000000000000000000000000000000000000001;
    mapping(address user => mapping(bytes32 partnerWithPeriod => bytes32 nextPartnerWithPeriod)) public
        partnerChangeLog;
    mapping(address partner => address nextPartner) public partnerList;

    event PartnerRegisteredForPeriod(address indexed user, address indexed partner, uint96 indexed period);
    event NewPartnerRegistered(address partner);

    constructor(uint96 _startTimestamp, uint96 _duration) {
        START_TIMESTAMP = _startTimestamp;
        DURATION = _duration;
    }

    function getCurrentPeriod() public view returns (uint96 period) {
        period = (uint96(block.timestamp) - START_TIMESTAMP) / DURATION;
    }

    function getPeriodAtTimestamp(uint256 timestamp) public view returns (uint96 period) {
        period = (uint96(timestamp) - START_TIMESTAMP) / DURATION;
    }

    function getPartnerAtPeriod(address user, uint96 period) public view returns (address partner) {
        bytes32 lastPartnerWithPeriod = partnerChangeLog[user][SENTINEL_32];
        if (lastPartnerWithPeriod == bytes32(0)) {
            // If no partner is found, return default partner;
            return address(0);
        }
        // In case: period > lastPeriod, loop until we find period <= period in partnerChangeLog
        while (lastPartnerWithPeriod != SENTINEL_32) {
            address lastPartner;
            uint96 lastPeriod;

            assembly {
                // Extract low 12 bytes (uint96)
                lastPeriod := and(lastPartnerWithPeriod, 0xffffffffffffffffffffffff)

                // Extract high 20 bytes
                lastPartner := shr(96, lastPartnerWithPeriod)
            }

            if (period >= lastPeriod) {
                return lastPartner;
            } else {
                lastPartnerWithPeriod = partnerChangeLog[user][lastPartnerWithPeriod];
            }
        }
    }

    function getPartnerAtPeriod(address[] memory user, uint96 period) public view returns (address[] memory) {
        address[] memory partners = new address[](user.length);
        for (uint256 i; i < user.length; i++) {
            address partner = getPartnerAtPeriod(user[i], period);
            partners[i] = partner;
        }
        return partners;
    }

    function getUsersAtPeriodForPartner(address[] memory user, address partner, uint96 period)
        public
        view
        returns (address[] memory)
    {
        uint256 userCount;
        for (uint256 i; i < user.length; i++) {
            address partnerFromPeriod = getPartnerAtPeriod(user[i], period);
            if (partnerFromPeriod == partner) {
                userCount++;
            }
        }

        address[] memory users = new address[](userCount);

        uint256 index = 0;
        for (uint256 i = 0; i < user.length; i++) {
            address partnerFromPeriod = getPartnerAtPeriod(user[i], period);
            if (partnerFromPeriod == partner) {
                users[index] = user[i];
                index++;
            }
        }

        return users;
    }

    function isPartnerRegistered(address partner) public view returns (bool) {
        return partnerList[partner] != address(0);
    }

    function registerPartner(address partner) external {
        require(partnerList[partner] == address(0));

        if (partnerList[SENTINEL_20] == address(0)) {
            partnerList[SENTINEL_20] = partner;
            partnerList[partner] = SENTINEL_20;
        } else {
            address lastPartner = partnerList[SENTINEL_20];
            partnerList[SENTINEL_20] = partner;
            partnerList[partner] = lastPartner;
        }

        emit NewPartnerRegistered(partner);
    }

    function unregisterPartner(address partnerToRemove) external {
        require(partnerToRemove == msg.sender);
        require(partnerList[partnerToRemove] != address(0));
        require(partnerToRemove != SENTINEL_20);

        address nextPartner = partnerList[partnerToRemove];
        address previousPartner = SENTINEL_20;

        // Traverse to find the previous partner
        while (partnerList[previousPartner] != partnerToRemove) {
            previousPartner = partnerList[previousPartner];
            require(previousPartner != address(0));
        }

        // Remove the partner by linking previous to next
        partnerList[previousPartner] = nextPartner;
        partnerList[partnerToRemove] = address(0);
    }

    function setPartnerNextPeriod(address partner) external {
        uint96 nextPeriod = getCurrentPeriod() + 1;
        address user = msg.sender;
        // bytes0: bytes19 = partner
        // bytes20: bytes31 = nextPeriod
        bytes32 partnerWithPeriod;

        assembly {
            // partnerWithPeriod := shl(partner, 96)
            partnerWithPeriod := shl(96, partner)
            partnerWithPeriod := or(partnerWithPeriod, nextPeriod)
        }

        bytes32 head = partnerChangeLog[user][SENTINEL_32];
        if (head == bytes32(0)) {
            // in the case of empty list
            partnerChangeLog[user][SENTINEL_32] = partnerWithPeriod;
            partnerChangeLog[user][partnerWithPeriod] = SENTINEL_32;

            emit PartnerRegisteredForPeriod(user, partner, nextPeriod);
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
            bytes32 lastPartnerWithPeriod = partnerChangeLog[user][SENTINEL_32];
            bytes32 nextPartnerWithPeriod = partnerChangeLog[user][lastPartnerWithPeriod];
            // user in Period X, and wants to update Period {X+1}, but the partner for next period is already set
            // only update the partner address
            // add new  head into linked list if not updated before

            if (lastPeriod == nextPeriod && lastPartner != partner) {
                delete partnerChangeLog[user][head];
                // update in the current head
                partnerChangeLog[user][SENTINEL_32] = partnerWithPeriod;
                partnerChangeLog[user][partnerWithPeriod] = nextPartnerWithPeriod;
            } else {
                // add new  head into linked list if not updated before
                partnerChangeLog[user][SENTINEL_32] = partnerWithPeriod;
                partnerChangeLog[user][partnerWithPeriod] = lastPartnerWithPeriod;
            }

            emit PartnerRegisteredForPeriod(user, partner, nextPeriod);
        }
    }
}
