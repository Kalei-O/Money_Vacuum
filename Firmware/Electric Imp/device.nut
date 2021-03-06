/*
Code originally from Aron Steg: http://forums.electricimp.com/discussion/comment/7904
Modified February 1st, 2014 by Nathan Seidle
Many great fixes were made by Aaron Steg, May 2014.

This code was modified slightly to work with the Electric Imp Shield 
from SparkFun: https://www.sparkfun.com/products/11401
The reset control was inverted and status LEDs re-routed but everything else was the same.
Zomg thank you Aron Steg: http://forums.electricimp.com/discussion/comment/7904

Two hardware modifications are required:

* Cut two RX/TX traces to 8/9 on the back of the Imp Shield then solder blob to 0/1
* Wire from P1 of Imp to RST on shield.

It takes the Arduino approximately 400ms from reset going high to be able to 
respond to incoming bootload commands.

Original license:

Copyright (c) 2014 Electric Imp
The MIT License (MIT)
http://opensource.org/licenses/MIT

*/

local NOCHAR = -1;

server.log("Device started, impee_id " + hardware.getimpeeid() + " and mac = " + imp.getmacaddress() );

//------------------------------------------------------------------------------------------------------------------------------
// Uart57 for TX/RX
SERIAL <- hardware.uart57;
SERIAL.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS);

// Set pin1 high for normal operation
// Set pin1 low to reset a standard Arduino
RESET <- hardware.pin1;
RESET.configure(DIGITAL_OUT);
RESET.write(1); //Leave Arduino in normal (non-reset) state

// Pin 9 is the yellow LED on the Imp Shield
ACTIVITY <- hardware.pin9;
ACTIVITY.configure(DIGITAL_OUT);
ACTIVITY.write(1);

// Pin 8 is the orange LED
LINK <- hardware.pin8;
LINK.configure(DIGITAL_OUT);
LINK.write(1);

// Sequence number
__seq <- 0x28;


//------------------------------------------------------------------------------------------------------------------------------
/* STK500 constants list, from AVRDUDE */
const MESSAGE_START       = 0x1B;
const TOKEN               = 0x0E;
const STK_OK              = 0x10;
const STK_FAILED          = 0x11;  // Not used
const STK_UNKNOWN         = 0x12;  // Not used
const STK_NODEVICE        = 0x13;  // Not used
const STK_INSYNC          = 0x14;  // ' '
const STK_NOSYNC          = 0x15;  // Not used
const ADC_CHANNEL_ERROR   = 0x16;  // Not used
const ADC_MEASURE_OK      = 0x17;  // Not used
const PWM_CHANNEL_ERROR   = 0x18;  // Not used
const PWM_ADJUST_OK       = 0x19;  // Not used
const CRC_EOP             = 0x20;  // 'SPACE'
const STK_GET_SYNC        = 0x30;  // '0'
const STK_GET_SIGN_ON     = 0x31;  // '1'
const STK_SET_PARAMETER   = 0x40;  // '@'
const STK_GET_PARAMETER   = 0x41;  // 'A'
const STK_SET_DEVICE      = 0x42;  // 'B'
const STK_SET_DEVICE_EXT  = 0x45;  // 'E'
const STK_ENTER_PROGMODE  = 0x50;  // 'P'
const STK_LEAVE_PROGMODE  = 0x51;  // 'Q'
const STK_CHIP_ERASE      = 0x52;  // 'R'
const STK_CHECK_AUTOINC   = 0x53;  // 'S'
const STK_LOAD_ADDRESS    = 0x55;  // 'U'
const STK_UNIVERSAL       = 0x56;  // 'V'
const STK_PROG_FLASH      = 0x60;  // '`'
const STK_PROG_DATA       = 0x61;  // 'a'
const STK_PROG_FUSE       = 0x62;  // 'b'
const STK_PROG_LOCK       = 0x63;  // 'c'
const STK_PROG_PAGE       = 0x64;  // 'd'
const STK_PROG_FUSE_EXT   = 0x65;  // 'e'
const STK_READ_FLASH      = 0x70; // 'p'
const STK_READ_DATA       = 0x71;  // 'q'
const STK_READ_FUSE       = 0x72;  // 'r'
const STK_READ_LOCK       = 0x73;  // 's'
const STK_READ_PAGE       = 0x74;  // 't'
const STK_READ_SIGN       = 0x75;  // 'u'
const STK_READ_OSCCAL     = 0x76;  // 'v'
const STK_READ_FUSE_EXT   = 0x77;  // 'w'
const STK_READ_OSCCAL_EXT = 0x78;  // 'x'


//------------------------------------------------------------------------------------------------------------------------------
function HEXDUMP(buf, len = null) {
    if (buf == null) return "null";
    if (len == null) {
        len = (typeof buf == "blob") ? buf.tell() : buf.len();
    }
    
    local dbg = "";
    for (local i = 0; i < len; i++) {
        local ch = buf[i];
        dbg += format("0x%02X ", ch);
    }
    
    return format("%s (%d bytes)", dbg, len)
}


//------------------------------------------------------------------------------------------------------------------------------
function SERIAL_READ(len = 100, timeout = 300) {
    
    local rxbuf = blob(len);
    local write = rxbuf.writen.bindenv(rxbuf);
    local read = SERIAL.read.bindenv(SERIAL);
    local hw = hardware;
    local ms = hw.millis.bindenv(hw);
    local started = ms();

    local charsRead = 0;
    LINK.write(0); //Turn LED on
    do {
        local ch = read();
        if (ch != -1) {
            write(ch, 'b')
            charsRead++;
            if(charsRead == len) break;
        }
    } while (ms() - started < timeout);
    LINK.write(1); //Turn LED off

    // Clean up any extra bytes
    while (SERIAL.read() != -1);
    
    if (rxbuf.tell() == 0) {
        return null;
    } else {
        return rxbuf;
    }
}


//------------------------------------------------------------------------------------------------------------------------------
function execute(command = null, param = null, response_length = 100, response_timeout = 300) {
    
    local send_buffer = null;
    if (command == null) {
        send_buffer = format("%c", CRC_EOP);
    } else if (param == null) {
        send_buffer = format("%c%c", command, CRC_EOP);
    } else if (typeof param == "array") {
        send_buffer = format("%c", command);
        foreach (datum in param) {
            switch (typeof datum) {
                case "string":
                case "blob":
                case "array":
                case "table":
                    foreach (adat in datum) {
                        send_buffer += format("%c", adat);
                    }
                    break;
                default:
                    send_buffer += format("%c", datum);
            }
        }
        send_buffer += format("%c", CRC_EOP);
    } else {
        send_buffer = format("%c%c%c", command, param, CRC_EOP);
    }
    
    // server.log("Sending: " + HEXDUMP(send_buffer));
    SERIAL.write(send_buffer);
    
    local resp_buffer = SERIAL_READ(response_length+2, response_timeout);
    // server.log("Received: " + HEXDUMP(resp_buffer));
    
    assert(resp_buffer != null);
    assert(resp_buffer.tell() >= 2);
    assert(resp_buffer[0] == STK_INSYNC);
    assert(resp_buffer[resp_buffer.tell()-1] == STK_OK);
    
    local tell = resp_buffer.tell();
    if (tell == 2) return blob(0);
    resp_buffer.seek(1);
    return resp_buffer.readblob(tell-2);
}


//------------------------------------------------------------------------------------------------------------------------------
function check_duino() {
    // Clear the read buffer
    SERIAL_READ(); 

    // Check everything we can check to ensure we are speaking to the correct boot loader
    local major = execute(STK_GET_PARAMETER, 0x81, 1);
    local minor = execute(STK_GET_PARAMETER, 0x82, 1);
    local invalid = execute(STK_GET_PARAMETER, 0x83, 1);
    local signature = execute(STK_READ_SIGN);
    assert(major.len() == 1 && minor.len() == 1);
    assert((major[0] >= 5) || (major[0] == 4 && minor[0] >= 4));
    assert(invalid.len() == 1 && invalid[0] == 0x03);
    assert(signature.len() == 3 && signature[0] == 0x1E && signature[1] == 0x95 && signature[2] == 0x0F);
}


//------------------------------------------------------------------------------------------------------------------------------
function program_duino(address16, data) {

    local addr8_hi = (address16 >> 8) & 0xFF;
    local addr8_lo = address16 & 0xFF;
    local data_len = data.len();
    
    execute(STK_LOAD_ADDRESS, [addr8_lo, addr8_hi], 0);
    execute(STK_PROG_PAGE, [0x00, data_len, 0x46, data], 0)
    local data_check = execute(STK_READ_PAGE, [0x00, data_len, 0x46], data_len)
    
    assert(data_check.len() == data_len);
    for (local i = 0; i < data_len; i++) {
        assert(data_check[i] == data[i]);
    }

}


//------------------------------------------------------------------------------------------------------------------------------
function bounce() {
    
    // Bounce the reset pin
    server.log("Bouncing the Arduino reset pin");
    imp.sleep(0.5);
    ACTIVITY.write(0); //Turn on LED
    RESET.write(0); //Reset Arduino
    imp.sleep(0.2);
    RESET.write(1); //Return reset to high, bootloader on Arduino now begins
    imp.sleep(0.3);
    check_duino();
    ACTIVITY.write(1); //Turn off LED
}

//------------------------------------------------------------------------------------------------------------------------------
function scan_serial() {
    local ch = null;
    local str = "";
    do {
        ch = SERIAL.read();
        if (ch != -1 && ch != 0) {
            str += format("%c", ch);
        }
    } while (ch != -1);
    
    if (str.len() > 0) {
        server.log("Serial: " + str);
    }
}

//------------------------------------------------------------------------------------------------------------------------------
function burn(pline) {
    if ("first" in pline) {
        server.log("Starting to burn");
        SERIAL.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS);
        bounce();
    } else if ("last" in pline) {
        server.log("Done!")
        agent.send("done", true);
        SERIAL.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS, check_for_incoming_reports);
        //check_for_incoming_reports(); //Begin polling for incoming strings

    } else {
        program_duino(pline.addr, pline.data);
    }
}


//------------------------------------------------------------------------------------------------------------------------------
// Look for incoming reports from Arduino
// Pass that data onto the Agent for parsing and posting to data.sparkfun.com
function check_for_incoming_reports() {
    
    //Get all the various bits from the Arduino over UART
    //server.log("Looking for report fields");
    
    //Wait for initial character to come in
    local result = NOCHAR;

    // Collect bytes
    local incomingStream = "";
    local counter = 0;
    while (result != '\n')  // Keep reading until we see a newline
    {
        counter = 0;
        while(result == NOCHAR)
        {
            result = SERIAL.read();
    
            if(result == NOCHAR)
            {
                imp.sleep(0.01);
                if(counter++ > 20) //Wait no more than 20ms for another character
                {
                    //server.log("Serial timeout error");
                    return(0); //Bail after 20ms max wait 
                }
            }
        }
        
        incomingStream += format("%c", result);

        result = SERIAL.read(); //Grab the next character in the que
    }
    
    //server.log("We heard: " + format("%s", incomingStream)); // Display in log window
    
    //server.log("Arduino read complete");

    hardware.pin9.write(1); //TX LED off

    // Send info to agent, that will in turn push to internet
    agent.send("postToInternet", incomingStream);
    
    check_for_incoming_reports();
}

//------------------------------------------------------------------------------------------------------------------------------
agent.on("burn", burn);
agent.send("ready", true);

hardware.configure(UART_57);    // Using UART on pins 5 and 7
SERIAL.configure(9600, 8, PARITY_NONE, 1, NO_CTSRTS, check_for_incoming_reports); // 9600 baud worked well, no parity, 1 stop bit, 8 data bits
