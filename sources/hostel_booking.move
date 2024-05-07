module hostel_booking::hostel_booking {
    use sui::transfer;
    use sui::sui::SUI;
    use std::string::String;
    use sui::coin::Coin;
    use sui::clock::Clock;
    use sui::object::{Self, UID, ID};
    use sui::balance::Balance;
    use sui::tx_context::TxContext;
    use sui::table::Table;

    // Constants for error codes
    const E_INSUFFICIENT_FUNDS: u64 = 1;
    const E_INVALID_COIN: u64 = 2;
    const E_NOT_STUDENT: u64 = 3;
    const E_INVALID_ROOM: u64 = 5;
    const E_NOT_INSTITUTION: u64 = 6;
    const E_INVALID_HOSTEL_BOOKING: u64 = 7;

    struct Institution has key {
        id: UID,
        name: String,
        student_fees: Table<ID, u64>, // Map of student_id to fees
        balance: Balance<SUI>,
        memos: Table<ID, RoomMemo>, // Map of student_id to RoomMemo
        institution_address: address
    }

    struct Student has key {
        id: UID,
        name: String,
        student_address: address,
        institution_id: ID,
        balance: Balance<SUI>,
    }

    struct RoomMemo has key, store {
        id: UID,
        room_id: ID,
        semester_payment: u64,
        minimum_fee: u64, // Minimum fee that the student has to pay
        institution_address: address 
    }

    struct HostelRoom has key {
        id: UID,
        name: String,
        room_size: u64,
        institution_address: address,
        beds_available: u64,
    }

    struct BookingRecord has key, store {
        id: UID,
        student_id: ID,
        room_id: ID,
        student_address: address,
        institution_address: address,
        paid_fee: u64,
        semester_payment: u64,
        booking_time: u64
    }

    // Create a new Institution object
    public fun create_institution(ctx: &mut TxContext, name: String) {
        let institution = Institution {
            id: object::new(ctx),
            name,
            student_fees: Table::new(ctx),
            balance: Balance::zero(),
            memos: Table::new(ctx),
            institution_address: tx_context::sender(ctx)
        };
        transfer::share_object(institution);
    }

    // Create a new Student object
    public fun create_student(ctx: &mut TxContext, name: String, institution_address: address) {
        let institution_id = object::id_from_address(institution_address);
        let student = Student {
            id: object::new(ctx),
            name,
            student_address: tx_context::sender(ctx),
            institution_id,
            balance: Balance::zero(),
        };
        transfer::share_object(student);
    }

    // Create a memo for a room
    public fun create_room_memo(
        institution: &mut Institution,
        semester_payment: u64,
        minimum_fee: u64,
        room_name: vector<u8>,
        room_size: u64,
        beds_available: u64,
        ctx: &mut TxContext
    ): HostelRoom {
        assert!(institution.institution_address == tx_context::sender(ctx), E_NOT_INSTITUTION);
        let room = HostelRoom {
            id: object::new(ctx),
            name: string::utf8(room_name),
            room_size,
            institution_address: institution.institution_address,
            beds_available
        };
        let memo = RoomMemo {
            id: object::new(ctx),
            room_id: object::uid_to_inner(&room.id),
            semester_payment,
            minimum_fee,
            institution_address: institution.institution_address
        };
        Table::add(&mut institution.memos, object::uid_to_inner(&room.id), memo);
        room
    }

    // Book a room
    public fun book_room(
        institution: &mut Institution,
        student: &mut Student,
        room: &mut HostelRoom,
        room_memo_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(institution.institution_address == tx_context::sender(ctx), E_NOT_INSTITUTION);
        assert!(student.institution_id == object::id_from_address(institution.institution_address), E_NOT_STUDENT);
        assert!(Table::contains(&institution.memos, room_memo_id), E_INVALID_HOSTEL_BOOKING);
        assert!(room.institution_address == institution.institution_address, E_INVALID_ROOM);
        assert!(room.beds_available > 0, E_INVALID_ROOM);

        let memo = Table::borrow(&institution.memos, room_memo_id);
        let booking_time = Clock::timestamp_ms(clock);
        let booking_record = BookingRecord {
            id: object::new(ctx),
            student_id: object::uid_to_inner(&student.id),
            room_id: object::uid_to_inner(&room.id),
            student_address: student.student_address,
            institution_address: institution.institution_address,
            paid_fee: memo.minimum_fee,
            semester_payment: memo.semester_payment,
            booking_time
        };
        transfer::public_freeze_object(booking_record);

        // Deduct the total fee from the student balance and add it to the institution balance
        let total_fee = memo.minimum_fee + memo.semester_payment;
        assert!(total_fee <= Balance::value(&student.balance), E_INSUFFICIENT_FUNDS);
        let amount_to_pay = Coin::take(&mut student.balance, total_fee, ctx);
        assert!(Coin::value(&amount_to_pay) > 0, E_INVALID_COIN);

        transfer::public_transfer(amount_to_pay, institution.institution_address);
        Table::add(&mut institution.student_fees, object::uid_to_inner(&student.id), memo.minimum_fee);

        room.beds_available -= 1;
        let _ = Table::remove(&mut institution.memos, room_memo_id);

        amount_to_pay
    }

    // Student adding funds to their account

    public fun top_up_student_balance(
        student: &mut Student,
        amount: Coin<SUI>,
        ctx: &mut TxContext
    ){
        assert!(student.student == tx_context::sender(ctx), ENotStudent);
        balance::join(&mut student.balance, coin::into_balance(amount));
    }

    // add the Payment fee to the institution balance

    public fun top_up_institution_balance(
        institution: &mut Institution,
        student: &mut Student,
        room: &mut HostelRoom,
        room_memo_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        // Can only be called by the student
        assert!(student.student == tx_context::sender(ctx), ENotStudent);
        let (amount_to_pay) = book_room(institution, student, room, room_memo_id, clock, ctx);
        balance::join(&mut institution.balance, coin::into_balance(amount_to_pay));
    }

    // Get the balance of the institution

    public fun get_institution_balance(institution: &Institution) : &Balance<SUI> {
        &institution.balance
    }

    // Institution can withdraw the balance

    public fun withdraw_funds(
        institution: &mut Institution,
        amount: u64,
        ctx: &mut TxContext
    ){
        assert!(institution.institution == tx_context::sender(ctx), ENotInstitution);
        assert!(amount <= balance::value(&institution.balance), EInsufficientFunds);
        let amount_to_withdraw = coin::take(&mut institution.balance, amount, ctx);
        transfer::public_transfer(amount_to_withdraw, institution.institution);
    }
    
    // Transfer the Ownership of the room to the student
    public entry fun transfer_room_ownership(
        student: &Student,
        room: &mut HostelRoom,
        ctx: &mut TxContext
    ){
        assert!(room.beds_available > 0, E_INVALID_ROOM); // Ensure there's an available bed
        assert!(room.institution_address == tx_context::sender(ctx), E_NOT_INSTITUTION);
        transfer::transfer(room, student.student_address);
        room.beds_available -= 1; // Decrement available beds as it's now owned by a student
    }

    // Student returns the room ownership
    public fun return_room(
        institution: &mut Institution,
        student: &mut Student,
        room: &mut HostelRoom,
        ctx: &mut TxContext
    ) {
        assert!(room.institution_address == institution.institution_address, E_INVALID_ROOM);
        assert!(student.institution_id == object::id_from_address(institution.institution_address), E_NOT_STUDENT);

        room.beds_available += 1; // Increment beds available since it's returned
    }

    // Add funds to a student's account
    public fun top_up_student_balance(
        student: &mut Student,
        amount: Coin<SUI>,
        ctx: &mut TxContext
    ){
        assert!(student.student_address == tx_context::sender(ctx), E_NOT_STUDENT);
        Balance::join(&mut student.balance, Coin::into_balance(amount));
    }

    // Withdraw funds from the institution
    public fun withdraw_funds(
        institution: &mut Institution,
        amount: u64,
        ctx: &mut TxContext
    ){
        assert!(institution.institution_address == tx_context::sender(ctx), E_NOT_INSTITUTION);
        assert!(amount <= Balance::value(&institution.balance), E_INSUFFICIENT_FUNDS);
        let amount_to_withdraw = Coin::take(&mut institution.balance, amount, ctx);
        transfer::public_transfer(amount_to_withdraw, institution.institution_address);
    }

}
