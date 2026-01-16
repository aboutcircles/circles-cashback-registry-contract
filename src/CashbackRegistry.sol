// SPDX-License-Identifier: AGPL3.0
pragma solidity ^0.8.20;

/// @title Cashback Registry
/// @notice A registry to record a user's cashback partner for a given period.
/// @dev This contract stores information about partners and user's cashback partner selections
/// in a linked list structure. It allows for querying a user's partner at any given period.
contract CashbackRegistry {
    /// @notice The timestamp when the first period starts.
    uint96 public immutable START_TIMESTAMP;
    /// @notice The duration of each period in seconds.
    uint96 public immutable DURATION;
    /// @dev Sentinel value for the partner change log linked list.
    bytes32 constant SENTINEL_32 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    /// @dev Sentinel value for the partner list linked list.
    address constant SENTINEL_20 = 0x0000000000000000000000000000000000000001;
    /// @notice The administrator of the contract.
    address public immutable ADMIN;

    /// @notice Stores the historical partner changes for a given user.
    /// @dev mapping(user => mapping(partnerWithPeriod => nextPartnerWithPeriod))
    /// This is a linked list for each user, where the key is a packed bytes32 containing the partner and period,
    /// and the value is the next packed bytes32 in the list.
    mapping(address user => mapping(bytes32 partnerWithPeriod => bytes32 nextPartnerWithPeriod)) public
        partnerChangeLog;
    /// @notice Stores the list of registered partners.
    /// @dev This is a linked list of partners, where the key is a partner address and the value is the next partner address.
    mapping(address partner => address nextPartner) public partnerList;

    /// @notice Emitted when a new partner is set for a user for a specific period.
    /// @param user The user for whom the partner is registered.
    /// @param partner The partner being registered.
    /// @param startTimestampOfPeriod The start timestamp of the period for which the partner is registered.
    event PartnerRegisteredForPeriod(
        address indexed user, address indexed partner, uint256 indexed startTimestampOfPeriod
    );
    /// @notice Emitted when a new partner is registered in the contract.
    /// @param partner The new partner's address.
    event NewPartnerRegistered(address indexed partner);

    /// @notice Emitted when a partner is unregistered from the contract.
    /// @param partner The unregistered partner's address.
    event PartnerUnregistered(address indexed partner);

    /// @notice Error thrown when a function is called by an unauthorized address.
    /// @param caller The address that attempted to call the function.
    error InvalidCaller(address caller);

    /// @notice Error thrown when a partner is not registered.
    /// @param partner The address of the partner that is not registered.
    error PartnerIsNotRegistered(address partner);

    /// @notice Error thrown when an invalid partner address is provided.
    /// @param partner The invalid partner address.
    error InvalidPartner(address partner);

    /// @notice Modifier to restrict function access to the admin.
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @notice Constructor to initialize the contract.
    /// @param _startTimestamp The timestamp when the first period starts.
    /// @param _duration The duration of each period in seconds.
    /// @param _admin The address of the administrator.
    constructor(uint96 _startTimestamp, uint96 _duration, address _admin) {
        START_TIMESTAMP = _startTimestamp;
        DURATION = _duration;
        ADMIN = _admin;
    }

    /// @notice Gets the current period based on the block timestamp.
    /// @return period The current period number.
    function getCurrentPeriod() public view returns (uint96 period) {
        period = (uint96(block.timestamp) - START_TIMESTAMP) / DURATION;
    }

    /// @notice Gets the period number for a given timestamp.
    /// @dev Need to consider when divided down. Each period X is defined by [START_TIMESTAMP + X*DURATION, START_TIMESTAMP + (X+1)*DURATION).
    /// @param timestamp The timestamp to get the period for.
    /// @return period The period number.
    function getPeriodAtTimestamp(uint256 timestamp) public view returns (uint96 period) {
        return timestamp < START_TIMESTAMP ? 0 : (uint96(timestamp) - START_TIMESTAMP) / DURATION;
    }

    /// @notice Given a period, return the start and end timestamp of the period.
    /// @param period The period number.
    /// @return startTimestamp The start timestamp of the period.
    /// @return endTimestamp The end timestamp of the period.
    function getStartEndTimestampForPeriod(uint96 period)
        public
        view
        returns (uint256 startTimestamp, uint256 endTimestamp)
    {
        startTimestamp = START_TIMESTAMP + period * DURATION;
        endTimestamp = START_TIMESTAMP + (period + 1) * DURATION;
    }

    /// @notice Gets the partner for a given user at a specific period.
    /// @param user The user's address.
    /// @param period The period number.
    /// @return partner The partner's address.
    function getPartnerAtPeriod(address user, uint96 period) public view returns (address partner) {
        assembly {
            // Calculate storage slot of partnerChangeLog[user]
            mstore(0, user)
            mstore(0x20, partnerChangeLog.slot)
            mstore(0x20, keccak256(0, 0x40))
            // Calculate second mapping slot of partnerChangeLog[user][SENTINEL]
            mstore(0, 0x01)
            mstore(0x20, keccak256(0, 0x40))
            partner := 0
            let lastPartnerWithPeriod := sload(mload(0x20)) // Read partnerChangeLog[user][SENTINEL]

            for {} iszero(eq(lastPartnerWithPeriod, 0x01)) {} {
                let lastPeriod := and(lastPartnerWithPeriod, 0xffffffffffffffffffffffff)
                let lastPartner := shr(96, lastPartnerWithPeriod)

                // if period >= lastPeriod
                if iszero(lt(period, lastPeriod)) {
                    partner := lastPartner
                    break
                }

                // else update to next node
                mstore(0, user)
                mstore(0x20, partnerChangeLog.slot)
                mstore(0x20, keccak256(0, 0x40))
                // calculate second mapping slot
                mstore(0, lastPartnerWithPeriod)
                mstore(0x20, keccak256(0, 0x40)) // second mapping of [user][lastPartnerWithPeriod]
                lastPartnerWithPeriod := sload(mload(0x20))
            }
        }
    }

    /// @notice Gets the partners for a list of users at a specific period.
    /// @param user An array of user addresses.
    /// @param period The period number.
    /// @return partners An array of partner addresses corresponding to the users.
    function getPartnerAtPeriod(address[] memory user, uint96 period) public view returns (address[] memory partners) {
        partners = new address[](user.length);
        for (uint256 i; i < user.length; i++) {
            address partner = getPartnerAtPeriod(user[i], period);
            partners[i] = partner;
        }
        return partners;
    }

    /// @notice Filters a list of users to find those associated with a specific partner at a given period.
    /// @param user An array of user addresses to filter.
    /// @param partner The partner to filter by.
    /// @param period The period number.
    /// @return users An array of user addresses that have the specified partner for the given period.
    function getUsersAtPeriodForPartner(address[] memory user, address partner, uint96 period)
        public
        view
        returns (address[] memory users)
    {
        assembly {
            let userArrLen := mload(user) // return the size of the user array
            let userArrElementLocation := add(user, 0x20)
            let userElement
            let lastPartnerWithPeriod
            let lastPeriod
            let lastPartner
            let end := add(userArrElementLocation, mul(userArrLen, 0x20))

            users := mload(0x40)
            mstore(0x40, add(mload(0x40), 0x20)) // need this step to make sure the last element of the array is correctly read
            // loop through each user in the array
            for {} lt(userArrElementLocation, end) {
                userArrElementLocation := add(userArrElementLocation, 0x20)
            } {
                userElement := mload(userArrElementLocation)

                mstore(0, userElement)
                mstore(0x20, partnerChangeLog.slot)
                mstore(0x20, keccak256(0, 0x40))

                mstore(0, 0x01)
                mstore(0x20, keccak256(0, 0x40))

                lastPartnerWithPeriod := sload(mload(0x20)) // read partnerChangeLog[user][SENTINEL]

                for {} iszero(eq(lastPartnerWithPeriod, 0x01)) {} {
                    lastPeriod := and(lastPartnerWithPeriod, 0xffffffffffffffffffffffff)
                    lastPartner := shr(96, lastPartnerWithPeriod)

                    if and(iszero(lt(period, lastPeriod)), eq(partner, lastPartner)) {
                        // if period >= lastPeriod && partner == lastPartner
                        // push the user into the new users array

                        // Increase free memory pointer by 0x20 for the new element
                        mstore(0x40, add(mload(0x40), 0x20))
                        // Increment array length
                        mstore(users, add(mload(users), 0x01))
                        // Store the new element in array
                        mstore(add(users, mul(mload(users), 0x20)), userElement)
                    }

                    // else update to next node
                    mstore(0, userElement)
                    mstore(0x20, partnerChangeLog.slot)
                    mstore(0x20, keccak256(0, 0x40))

                    mstore(0, lastPartnerWithPeriod)
                    mstore(0x20, keccak256(0, 0x40))
                    lastPartnerWithPeriod := sload(mload(0x20)) // read partnerChangeLog[user][lastPartnerWithPeriod]

                    // Stop when it reaches partnerChangeLog[user][SENTINEL]
                    if or(eq(lastPartnerWithPeriod, 0x01), iszero(lastPartnerWithPeriod)) {
                        break
                    }
                }
            }
        }
    }

    /// @notice Checks if a partner is registered in the contract.
    /// @param partner The partner's address.
    /// @return isRegistered A boolean indicating whether the partner is registered.
    function isPartnerRegistered(address partner) public view returns (bool isRegistered) {
        isRegistered = partnerList[partner] != address(0);
        return isRegistered;
    }

    /// @notice Registers a new partner.
    /// @dev Pushes a partner into the linked list and emits a NewPartnerRegistered event.
    /// @param partner The address of the partner to register.
    function registerPartner(address partner) external onlyAdmin {
        if (partner == address(0) || partner == SENTINEL_20 || isPartnerRegistered(partner)) {
            revert InvalidPartner(partner);
        }

        if (partnerList[SENTINEL_20] == address(0)) {
            partnerList[partner] = SENTINEL_20;
        } else {
            address lastPartner = partnerList[SENTINEL_20];
            partnerList[partner] = lastPartner;
        }

        partnerList[SENTINEL_20] = partner;

        emit NewPartnerRegistered(partner);
    }

    /// @notice Unregisters a partner.
    /// @dev Removes a partner from the linked list.
    /// @param partnerToRemove The address of the partner to unregister.
    function unregisterPartner(address partnerToRemove) external onlyAdmin {
        if (!isPartnerRegistered(partnerToRemove) || partnerToRemove == address(0) || partnerToRemove == SENTINEL_20) {
            revert InvalidPartner(partnerToRemove);
        }

        address nextPartner = partnerList[partnerToRemove];
        address previousPartner = SENTINEL_20;

        // Traverse to find the previous partner
        while (partnerList[previousPartner] != partnerToRemove) {
            previousPartner = partnerList[previousPartner];
            //  require(previousPartner != address(0));
        }

        // Remove the partner by linking previous to next
        partnerList[previousPartner] = nextPartner;
        partnerList[partnerToRemove] = address(0);

        emit PartnerUnregistered(partnerToRemove);
    }

    /// @notice Sets the partner for a user for the next period.
    /// @dev Can be called by the user to set their own partner for the next period, or by the admin for the current period.
    /// @param user The user's address.
    /// @param partner The partner's address.
    /// @return nextStartTimestamp The start timestamp of the period for which the partner is set.
    function setPartnerForNextPeriod(address user, address partner) external returns (uint256 nextStartTimestamp) {
        if (msg.sender != ADMIN && msg.sender != user) {
            revert InvalidCaller(msg.sender);
        }
        if (!isPartnerRegistered(partner)) revert PartnerIsNotRegistered(partner);

        uint96 updateForPeriod = msg.sender == ADMIN ? getCurrentPeriod() : getCurrentPeriod() + 1;
        nextStartTimestamp = START_TIMESTAMP + updateForPeriod * DURATION;

        bytes32 partnerWithPeriod = _getPartnerWithPeriod(partner, updateForPeriod);

        bytes32 head = partnerChangeLog[user][SENTINEL_32];
        if (head == bytes32(0)) {
            // in the case of empty list
            partnerChangeLog[user][SENTINEL_32] = partnerWithPeriod;
            partnerChangeLog[user][partnerWithPeriod] = SENTINEL_32;
        } else {
            // find out if this period is the same as head
            (address lastPartner, uint96 lastPeriod) = _getPartnerAndPeriod(head);

            bytes32 lastPartnerWithPeriod = head;
            bytes32 nextPartnerWithPeriod = partnerChangeLog[user][lastPartnerWithPeriod];
            if (lastPartner == partner) return 0; // No change when partner is the same
            if (lastPeriod == updateForPeriod && lastPartner != partner) {
                // user in Period X, and wants to update Period {X+1}, but the partner for next period is already set
                // only update the partner address
                delete partnerChangeLog[user][head];
                // update in the current head
                partnerChangeLog[user][partnerWithPeriod] = nextPartnerWithPeriod;
            } else {
                // add new  head into linked list if not updated before
                partnerChangeLog[user][partnerWithPeriod] = lastPartnerWithPeriod;
            }
            partnerChangeLog[user][SENTINEL_32] = partnerWithPeriod;
        }

        emit PartnerRegisteredForPeriod(user, partner, nextStartTimestamp);
        return nextStartTimestamp;
    }

    /// @notice Decodes a bytes32 value into a partner address and a period number.
    /// @param partnerWithPeriod The encoded bytes32 value.
    /// @return partner The decoded partner address.
    /// @return period The decoded period number.
    function _getPartnerAndPeriod(bytes32 partnerWithPeriod) internal pure returns (address partner, uint96 period) {
        assembly {
            // Extract low 12 bytes (uint96)
            period := and(partnerWithPeriod, 0xffffffffffffffffffffffff)

            // Extract high 20 bytes
            partner := shr(96, partnerWithPeriod)
        }
    }

    /// @notice Encodes a partner address and a period number into a bytes32 value.
    /// @param partner The partner address.
    /// @param period The period number.
    /// @return partnerWithPeriod The encoded bytes32 value.
    function _getPartnerWithPeriod(address partner, uint96 period) internal pure returns (bytes32 partnerWithPeriod) {
        assembly {
            partnerWithPeriod := shl(96, partner)
            partnerWithPeriod := or(partnerWithPeriod, period)
        }
    }
}
