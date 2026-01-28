// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

/// @title Cashback Registry
/// @notice A registry to record a user's cashback partner for a given period.
/// @dev This contract stores information about partners and user's cashback partner selections
/// in a linked list structure. It allows for querying a user's partner at any given period.
contract CashbackRegistry {
    /// @notice The timestamp when the first period starts.
    uint96 public startTimestamp;
    /// @dev Sentinel value for the partner change log linked list.
    bytes32 constant SENTINEL_32 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    /// @dev Sentinel value for the partner list linked list.
    address constant SENTINEL_20 = 0x0000000000000000000000000000000000000001;
    /// @notice The administrator of the contract.
    address public immutable ADMIN;
    /// @notice The duration of each period in seconds.
    uint96 public duration;

    /// Record for the last duration changed
    uint96 public lastDurationBeforeDurationChange;
    uint96 public lastStartTimestampBeforeDurationChange;

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

    event DurationUpdated(uint96 indexed newDuration, uint96 indexed oldDuration);

    /// @notice Error thrown when a function is called by an unauthorized address.
    /// @param caller The address that attempted to call the function.
    error InvalidCaller(address caller);

    /// @notice Error thrown when a function is called by non admin address.
    error OnlyAdmin();

    /// @notice Error thrown when a partner is not registered.
    /// @param partner The address of the partner that is not registered.
    error PartnerIsNotRegistered(address partner);

    /// @notice Error thrown when a partner is already registered.
    /// @param partner The address of the partner that is already registered.
    error PartnerAlreadyRegistered(address partner);

    /// @notice Error thrown when an invalid partner address is provided.
    /// @param partner The invalid partner address.
    error InvalidAddress(address partner);

    /// @notice Modifier to restrict function access to the admin.
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) {
            revert OnlyAdmin();
        }
        _;
    }

    /// @notice Constructor to initialize the contract.
    /// @param _startTimestamp The timestamp when the first period starts.
    /// @param _duration The duration of each period in seconds.
    /// @param _admin The address of the administrator.
    constructor(uint96 _startTimestamp, uint96 _duration, address _admin) {
        startTimestamp = _startTimestamp;
        duration = _duration;
        ADMIN = _admin;
    }

    // [startTS, startTS + duration - 1] -> [startTS + duration, startTS + 2*duration - 1]
    /// Given a timestamp, return the start and end timestamp of the period where the timestamp is in
    function getPeriodAtTimestamp(uint96 timestamp)
        public
        view
        returns (uint256 _startTimestamp, uint256 _endTimestamp)
    {
        // Use the previous startTimestamp and duration if the timestamp is less than startTiemstamp
        (uint96 startTimestampForDuration, uint96 durationForCalculation) = timestamp < startTimestamp
            ? (lastStartTimestampBeforeDurationChange, lastDurationBeforeDurationChange)
            : (startTimestamp, duration);

        (, uint256 r) = _getQuotientResidue((timestamp - startTimestampForDuration), durationForCalculation);

        if (r == 0) {
            // when timestamp is at divisible, then it is at startTimestamp
            unchecked {
                _startTimestamp = timestamp;
                _endTimestamp = timestamp + durationForCalculation - 1;
            }
        } else {
            unchecked {
                // if not divisible, timestamp is can either 1) be in the middle, or 2) at the end timestamp
                _startTimestamp = timestamp - r;
                _endTimestamp = _startTimestamp + durationForCalculation - 1;
            }
        }
    }

    /// @notice Gets the current period based on the block timestamp.
    /// @return _startTimestamp The current period's startTimestamp.
    /// @return _endTimestamp The current period's endTimestamp
    function getCurrentPeriod() public view returns (uint256 _startTimestamp, uint256 _endTimestamp) {
        (_startTimestamp, _endTimestamp) = getPeriodAtTimestamp(uint96(block.timestamp));
    }

    /// @notice Gets the partner for a given user at a specific period.
    /// @param _user The user's address.
    /// @param _timestamp The period number.
    /// @return partner The partner's address.
    function getPartnerAtTimestamp(address _user, uint96 _timestamp) public view returns (address partner) {
        assembly {
            // Calculate storage slot of partnerChangeLog[user]
            let userKey := mload(0x40)
            mstore(0, _user)
            mstore(0x20, partnerChangeLog.slot)
            mstore(userKey, keccak256(0, 0x40)) // store the partnerChangeLog[_user] slot at fmp
            mstore(0x40, add(userKey, 0x20)) // update free memory pointer
            // Calculate second mapping slot of partnerChangeLog[_user][SENTINEL]
            mstore(0, 0x01)
            mstore(0x20, mload(userKey))
            mstore(0x20, keccak256(0, 0x40))
            let lastPartnerWithStartTimestamp := sload(mload(0x20)) // Read partnerChangeLog[_user][SENTINEL]

            for {} iszero(eq(lastPartnerWithStartTimestamp, 0x01)) {} {
                let lastStartTimestampInList := and(lastPartnerWithStartTimestamp, 0xffffffffffffffffffffffff)
                let lastPartnerInList := shr(96, lastPartnerWithStartTimestamp)

                // if _timestamp >= lastStartTimestampInList
                if iszero(lt(_timestamp, lastStartTimestampInList)) {
                    partner := lastPartnerInList
                    break
                }

                // // else update to next node
                // calculate second mapping slot
                mstore(0, lastPartnerWithStartTimestamp)
                mstore(0x20, mload(userKey)) // load the slot partnerChangeLog[_user] from
                mstore(0x20, keccak256(0, 0x40)) // second mapping of [_user][lastPartnerWithStartTimestamp]
                lastPartnerWithStartTimestamp := sload(mload(0x20))
            }
        }
    }

    /// @notice Gets the partners for a list of users at a specific period.
    /// @param _user An array of user addresses.
    /// @param _timestamp The _timestamp number.
    /// @return partners An array of partner addresses corresponding to the users.
    function getPartnerAtTimestamp(address[] memory _user, uint96 _timestamp)
        public
        view
        returns (address[] memory partners)
    {
        partners = new address[](_user.length);
        for (uint256 i; i < _user.length; i++) {
            address partner = getPartnerAtTimestamp(_user[i], _timestamp);
            partners[i] = partner;
        }
        return partners;
    }

    /// @notice Filters a list of users to find those associated with a specific partner at a given timestamp.
    /// @param _user An array of user addresses to filter.
    /// @param _partner The partner to filter by.
    /// @param _timestamp The period number.
    /// @return users An array of user addresses that have the specified partner for the given period.
    function getUsersAtTimestampForPartner(address[] memory _user, address _partner, uint96 _timestamp)
        public
        view
        returns (address[] memory users)
    {
        assembly {
            let userArrLen := mload(_user) // return the size of the user array
            let userArrElementLocation := add(_user, 0x20)
            let userElement
            let lastPartnerWithStartTimestamp
            let lastStartTimestampInList
            let lastPartnerInList
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

                lastPartnerWithStartTimestamp := sload(mload(0x20)) // read partnerChangeLog[user][SENTINEL]

                for {} iszero(eq(lastPartnerWithStartTimestamp, 0x01)) {} {
                    lastStartTimestampInList := and(lastPartnerWithStartTimestamp, 0xffffffffffffffffffffffff)
                    lastPartnerInList := shr(96, lastPartnerWithStartTimestamp)

                    if and(iszero(lt(_timestamp, lastStartTimestampInList)), eq(_partner, lastPartnerInList)) {
                        // if _timestamp >= lastStartTimestampInList && _partner == lastPartnerInList
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

                    mstore(0, lastPartnerWithStartTimestamp)
                    mstore(0x20, keccak256(0, 0x40))
                    lastPartnerWithStartTimestamp := sload(mload(0x20)) // read partnerChangeLog[user][lastPartnerWithStartTimestamp]

                    // Stop when it reaches partnerChangeLog[user][SENTINEL]
                    if or(eq(lastPartnerWithStartTimestamp, 0x01), iszero(lastPartnerWithStartTimestamp)) {
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
        if (partner == address(0) || partner == SENTINEL_20) {
            revert InvalidAddress(partner);
        }

        if (isPartnerRegistered(partner)) {
            revert PartnerAlreadyRegistered(partner);
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
        if (partnerToRemove == address(0) || partnerToRemove == SENTINEL_20) {
            revert InvalidAddress(partnerToRemove);
        }
        if (!isPartnerRegistered(partnerToRemove)) {
            revert PartnerIsNotRegistered(partnerToRemove);
        }

        address nextPartner = partnerList[partnerToRemove];
        address previousPartner = SENTINEL_20;

        // Traverse to find the previous partner
        while (partnerList[previousPartner] != partnerToRemove) {
            previousPartner = partnerList[previousPartner];
        }

        // Remove the partner by linking previous to next
        partnerList[previousPartner] = nextPartner;
        partnerList[partnerToRemove] = address(0);

        emit PartnerUnregistered(partnerToRemove);
    }

    /// @notice Sets the partner for a user for the next period.
    /// @dev Can be called by the user to set their own partner for the next period, or by the admin for the current period.
    /// @param _user The user's address.
    /// @param _partner The partner's address.
    /// @return nextStartTimestamp The start timestamp of the period for which the partner is set.
    function setPartnerForNextPeriod(address _user, address _partner) external returns (uint256 nextStartTimestamp) {
        if (msg.sender != ADMIN && msg.sender != _user) {
            revert InvalidCaller(msg.sender);
        }

        if (_user == address(0)) revert InvalidAddress(_user);
        if (!isPartnerRegistered(_partner)) revert PartnerIsNotRegistered(_partner);

        (uint256 _startTimestamp, uint256 _endTimestamp) = getCurrentPeriod();
        // Update this period if msg.sender == ADMIN, if not, update next period
        _startTimestamp = msg.sender == ADMIN ? _startTimestamp : _startTimestamp + duration;
        _endTimestamp = msg.sender == ADMIN ? _endTimestamp : startTimestamp + duration - 1;

        // store the startTimestamp of the period
        bytes32 partnerWithStartTimestamp = _getPartnerWithStartTimestamp(_partner, uint96(_startTimestamp));

        bytes32 head = partnerChangeLog[_user][SENTINEL_32];
        if (head == bytes32(0)) {
            // in the case of empty list
            partnerChangeLog[_user][SENTINEL_32] = partnerWithStartTimestamp;
            partnerChangeLog[_user][partnerWithStartTimestamp] = SENTINEL_32;
        } else {
            // find out if this period is the same as head
            (address lastPartner, uint96 lastStartTs) = _getPartnerAndStartTimestamp(head);

            bytes32 lastPartnerWithStartTimestamp = head;
            bytes32 nextPartnerWithStartTimestamp = partnerChangeLog[_user][lastPartnerWithStartTimestamp];
            if (lastPartner == _partner) return 0; // No change when partner is the same
            if (lastStartTs == startTimestamp && lastPartner != _partner) {
                // user in Period X, and wants to update Period {X+1}, but the partner for next period is already set
                // only update the partner address
                delete partnerChangeLog[_user][head];
                // update in the current head
                partnerChangeLog[_user][partnerWithStartTimestamp] = nextPartnerWithStartTimestamp;
            } else {
                // add new  head into linked list if not updated before
                partnerChangeLog[_user][partnerWithStartTimestamp] = lastPartnerWithStartTimestamp;
            }
            partnerChangeLog[_user][SENTINEL_32] = partnerWithStartTimestamp;
        }

        emit PartnerRegisteredForPeriod(_user, _partner, _startTimestamp);
        return _startTimestamp;
    }

    function setDuration(uint96 _duration) external onlyAdmin {
        lastDurationBeforeDurationChange = duration;
        lastStartTimestampBeforeDurationChange = startTimestamp;

        (, uint256 _endTimestamp) = getCurrentPeriod();

        startTimestamp = uint96(_endTimestamp + 1);
        duration = _duration;

        emit DurationUpdated(duration, lastDurationBeforeDurationChange);
    }

    /// @notice Decodes a bytes32 value into a partner address and a period number.
    /// @param partnerWithStartTimestamp The encoded bytes32 value.
    /// @return partner The decoded partner address.
    /// @return startTs The decoded period number.
    function _getPartnerAndStartTimestamp(bytes32 partnerWithStartTimestamp)
        internal
        pure
        returns (address partner, uint96 startTs)
    {
        assembly {
            // Extract low 12 bytes (uint96)
            startTs := and(partnerWithStartTimestamp, 0xffffffffffffffffffffffff)

            // Extract high 20 bytes
            partner := shr(96, partnerWithStartTimestamp)
        }
    }

    /// @notice Encodes a partner address and a period number into a bytes32 value.
    /// @param partner The partner address.
    /// @param startTs The start timestamp.
    /// @return partnerWithStartTimestamp The encoded bytes32 value.
    function _getPartnerWithStartTimestamp(address partner, uint96 startTs)
        internal
        pure
        returns (bytes32 partnerWithStartTimestamp)
    {
        assembly {
            partnerWithStartTimestamp := shl(96, partner)
            partnerWithStartTimestamp := or(partnerWithStartTimestamp, startTs)
        }
    }

    function _getQuotientResidue(uint256 number, uint256 d)
        internal
        pure
        returns (uint256 quotient, uint256 remainder)
    {
        quotient = number / d;
        remainder = number == (quotient * d) ? 0 : number - (quotient * d);
    }
}
