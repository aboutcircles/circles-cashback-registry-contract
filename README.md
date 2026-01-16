# Cashback Registry

Cashback Registry contract records the user and cashback partner data on chain. User can pick one cashback partner for the next period. Partner can query the contract for eligible users that have selected them as partner, and distribute cashback reward to the users.

## Smart contract design

User-Partner relationship is tied to each period, where user can update their cashback partner for period X+1 by the end of period X. Each period is determined by `[START_TIMESTAMP + (PERIOD X)*DURATION, START_TIMESTAMP + (PERIOD X+1)*DURATION)`

```mermaid
graph TD
   subgraph Timeline["📅 Period Timeline"]
        T1[Period X-1]
        T2[User Sets Partner<br/>for Period X]
        T3[Period X Starts]
        T4[Partner Queries Users<br/>from Period X-1]
        T5[Cashback Distribution<br/>in Period X]

        T1 --> T2
        T2 --> T3
        T3 --> T4
        T4 --> T5
    end
```

The workflow between User, Admin and Partner is shown in the graph below:

```mermaid
graph TD
Start([Start])

    subgraph Admin["👑 Admin Workflow"]
        A1[Admin Registers Partner]
        A2[registerPartner partner]
        A3{Partner Valid?}
        A4[Add to partnerList]
        A5[Emit NewPartnerRegistered]
        A6[Admin Unregisters Partner]
        A7[unregisterPartner partner]
        A8[Remove from partnerList]
        A9[Emit PartnerUnregistered]
        A10[Admin Sets Partner for User<br/>Current Period]
        A11[setPartnerForNextPeriod user, partner]
        A12[Set for Current Period]

        A1 --> A2
        A2 --> A3
        A3 -->|Yes| A4
        A4 --> A5
        A3 -->|No| AErr[Revert: InvalidPartner]

        A6 --> A7
        A7 --> A8
        A8 --> A9

        A10 --> A11
        A11 --> A12
    end

    subgraph User["👤 User Workflow"]
        U1[User Logs into GnosisPay]
        U2[Select Cashback Partner<br/>from List]
        U3{Partner<br/>Registered?}
        U4[Call setPartnerForNextPeriod<br/>user, partner]
        U5[Update partnerChangeLog]
        U6{Already Set for<br/>Next Period?}
        U7[Update Head Node<br/>Same Period]
        U8[Add New Node<br/>New Period]
        U9[Emit PartnerRegisteredForPeriod]
        U10[Partner Active from<br/>Next Period]
        U11[User Can Change Partner<br/>Multiple Times in Period]

        U1 --> U2
        U2 --> U3
        U3 -->|No| UErr[Error: Partner Not Registered]
        U3 -->|Yes| U4
        U4 --> U5
        U5 --> U6
        U6 -->|Yes| U7
        U6 -->|No| U8
        U7 --> U9
        U8 --> U9
        U9 --> U10
        U10 --> U11
        U11 -.->|Within Period X-1| U2
    end

    subgraph Partner["🏢 Partner Workflow"]
        P1[Partner Wants to<br/>Distribute Cashback]
        P2{Query for<br/>Which Period?}
        P3[getCurrentPeriod]
        P4[Calculate Target Period<br/>period = current - 1]
        P5[Prepare User List<br/>address users]
        P6[getUsersAtPeriodForPartner<br/>users, partner, period]
        P7[Filter Eligible Users<br/>who selected this partner]
        P8[Return Filtered Users]
        P9[Distribute Cashback<br/>to Eligible Users]
        P10[Listen to Events]
        P11[Index PartnerRegisteredForPeriod<br/>Events]
        P12[Track User-Partner<br/>Relationships]

        P1 --> P2
        P2 -->|Last Week| P3
        P3 --> P4
        P4 --> P5
        P5 --> P6
        P6 --> P7
        P7 --> P8
        P8 --> P9

        P10 --> P11
        P11 --> P12
        P12 -.->|Reference Data| P6
    end

    Start --> Admin
    Start --> User
    Start --> Partner

    A5 -.->|Partner Available| U2
    U9 -.->|Event Emitted| P11

```
