-- ==========================================
-- STEP 1: WIPE OLD TEST TABLES (Clean Slate)
-- ==========================================
DROP TABLE IF EXISTS booked_seats CASCADE;
DROP TABLE IF EXISTS bookings CASCADE;
DROP TABLE IF EXISTS events CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- ==========================================
-- STEP 2: CREATE FRESH, PERFECT TABLES
-- ==========================================
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    phone TEXT,
    alt_phone TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE events (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    date DATE NOT NULL
);

-- Insert the main event
INSERT INTO events (id, name, date) VALUES (1, 'Kathak Dance Event', '2026-10-15');

CREATE TABLE bookings (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    event_id INT REFERENCES events(id),
    tickets INT NOT NULL,
    total_amount INT NOT NULL,
    branch TEXT,
    seats TEXT[],
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE booked_seats (
    id SERIAL PRIMARY KEY,
    seat_number TEXT NOT NULL UNIQUE,
    booking_id INT REFERENCES bookings(id),
    status TEXT DEFAULT 'CONFIRMED',
    locked_until TIMESTAMP WITH TIME ZONE,
    razorpay_order_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- STEP 3: ADD 5-MINUTE HOLD FUNCTION
-- ==========================================
CREATE OR REPLACE FUNCTION hold_seats_for_checkout(
    chosen_seats TEXT[],
    order_ref TEXT
)
RETURNS JSON AS $$
DECLARE
    seat TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM booked_seats 
        WHERE seat_number = ANY(chosen_seats) 
          AND (status = 'CONFIRMED' OR (status = 'HOLD' AND locked_until > NOW()))
    ) THEN
        RAISE EXCEPTION 'One or more seats are currently held by another user or already booked!';
    END IF;

    DELETE FROM booked_seats 
    WHERE seat_number = ANY(chosen_seats) 
      AND status = 'HOLD' 
      AND locked_until <= NOW();

    FOREACH seat IN ARRAY chosen_seats
    LOOP
        INSERT INTO booked_seats (seat_number, status, locked_until, razorpay_order_id)
        VALUES (seat, 'HOLD', NOW() + INTERVAL '5 minutes', order_ref)
        ON CONFLICT (seat_number) 
        DO UPDATE SET 
            status = 'HOLD',
            locked_until = NOW() + INTERVAL '5 minutes',
            razorpay_order_id = order_ref;
    END LOOP;

    RETURN json_build_object('success', true, 'message', 'Seats held for 5 minutes');
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- STEP 4: ADD FINAL BOOKING FUNCTION
-- ==========================================
CREATE OR REPLACE FUNCTION safely_book_exact_seats(
    buyer_name TEXT,
    buyer_email TEXT,
    buyer_phone TEXT,
    buyer_alt_phone TEXT,
    selected_branch TEXT,
    chosen_seats TEXT[],
    total_price INT,
    order_ref TEXT
)
RETURNS JSON AS $$
DECLARE
    customer_user_id INT;
    created_booking_id INT;
    seat TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM booked_seats 
        WHERE seat_number = ANY(chosen_seats) 
          AND status = 'CONFIRMED'
    ) THEN
        RAISE EXCEPTION 'Booking failed: These seats have already been confirmed.';
    END IF;

    SELECT id INTO customer_user_id FROM users WHERE email = buyer_email;
    IF customer_user_id IS NULL THEN
        INSERT INTO users (name, email, phone, alt_phone)
        VALUES (buyer_name, buyer_email, buyer_phone, buyer_alt_phone)
        RETURNING id INTO customer_user_id;
    ELSE
        UPDATE users 
        SET phone = buyer_phone, alt_phone = buyer_alt_phone, name = buyer_name 
        WHERE id = customer_user_id;
    END IF;

    INSERT INTO bookings (user_id, event_id, tickets, total_amount, branch, seats)
    VALUES (customer_user_id, 1, array_length(chosen_seats, 1), total_price, selected_branch, chosen_seats)
    RETURNING id INTO created_booking_id;

    FOREACH seat IN ARRAY chosen_seats
    LOOP
        UPDATE booked_seats 
        SET status = 'CONFIRMED', 
            booking_id = created_booking_id,
            locked_until = NULL
        WHERE seat_number = seat;
    END LOOP;

    RETURN json_build_object(
        'booking_id', created_booking_id,
        'seats', chosen_seats,
        'total_amount', total_price
    );
END;
$$ LANGUAGE plpgsql;