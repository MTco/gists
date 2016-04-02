/* -*- Mode: C -*-
   Arduino code for jwz's curtain controller
   Copyright © 2011-2016 Jamie Zawinski <jwz@jwz.org>

   Permission to use, copy, modify, distribute, and sell this software and its
   documentation for any purpose is hereby granted without fee, provided that
   the above copyright notice appear in all copies and that both that
   copyright notice and this permission notice appear in supporting
   documentation.  No representations are made about the suitability of this
   software for any purpose.  It is provided "as is" without express or 
   implied warranty.

   See http://www.jwz.org/curtain/ for details.

   An Arduino Uno, Ethernet shield, and Adafruit Servo controller are used to
   turn a motor on and off, forward or backward, to open and close curtains.
   A pair of Hall Effect sensors are used to determine when the curtain has
   reached either end of the track.

   The device also has a momentary push-button on it, which behaves like
   the TOGGLE command.

   It reads commands from either the serial port or the ethernet connection.

   All of these commands print "OK" once they have started operating:

      OPEN    -- Open the curtain if it's not open.
      CLOSE   -- Close the curtain if it's open.
      STOP    -- Turn off the motor right now.
      TOGGLE  -- If running, stop.  If not running, open or close.

   Different responses:

      QUERY   -- What is the current state?  Prints one of:
                 OPEN, CLOSED, OPENING, CLOSING
                 followed by the duration of the last command.
      HELP    -- Lists commands.

   Output lines beginning with "-" are not command responses, but are
   asynchronous status messages, useful for debugging.

   Libraries used:
    https://learn.adafruit.com/adafruit-motor-shield-v2-for-arduino/install-software

   Created: 16-Jan-2016
 */


#include <SPI.h>
#include <Ethernet.h>
#include <Wire.h>
//#include <EEPROM.h>
#include <Adafruit_MotorShield.h>
//#include <Adafruit_SleepyDog.h>

#define time_t unsigned long  // (not actually time_t)
#define FSTRING const __FlashStringHelper *

// SERIOUSLY??  I am expected to *type in the number printed on the board*?
//
static uint8_t mac[] = { 0x90, 0xA2, 0xDA, 0x00, 0xE3, 0xCB };

static int16_t listen_port = 10001;


//                  0  // (unavailable: RX)
//                  1  // (unavailable: TX)
#define LED1_PIN    2  // LED indicating open or running
#define LED2_PIN    3  // LED indicating closed or running
//                  4  // (unavailable: used by Ethernet Shield W5100)
#define SENSOR1_PIN 5  // Hall effect sensor for closed curtain
#define SENSOR2_PIN 6  // Hall effect sensor for open curtain
#define MANUAL_PIN  7  // The toggle button on the box
//                  8  // (unused, available)
//                  9  // (unused, available)
//                  10-13 (unavailable: used by Ethernet Shield W5100)

// #define DEBUG 1


// Header on the sub-board:
//
//	0  MANUAL_PIN
//	1  Gnd
//
//	2  motor A
//	3  motor B
//
//	4  SENSOR1_PIN
//	5  SENSOR2_PIN
//	6  +5v
//	7  Gnd

#define CMD_UNKNOWN    100
#define CMD_OPEN       101
#define CMD_CLOSE      102
#define CMD_OPEN_SLOW  103
#define CMD_CLOSE_SLOW 104
#define CMD_STOP       105
#define CMD_TOGGLE     106
#define CMD_TOGGLE2    107
#define CMD_TICK       108
#define CMD_QUERY      109
#define CMD_HELP       110

#define CURTAIN_ERROR  0
#define CURTAIN_OPEN   1
#define CURTAIN_MIDDLE 2
#define CURTAIN_CLOSED 3


// When changing the direction of the motor, we have to wait this long
// to avoid weirdness.
//
#define MOTOR_HYSTERESIS 1000

// Ignore state changes in momentary switches that happen too fast.
//
#define DEBOUNCE_HYSTERESIS 50

// If the motor has been running for this many seconds, emergency stop.
// That must mean that something has gone wrong, so let's not burn the
// thing out.
//
#ifdef DEBUG
# define MAX_RUNTIME 15
#else
# define MAX_RUNTIME (60 * 2)
#endif


EthernetServer server = 0;
EthernetClient client = 0;
bool server_initted = false;  // Whether ethernet is up and listening.
bool client_initted = false;  // Whether a client is connected.


char cmd_buffer[20];

// Create the motor shield object with the default I2C address.
Adafruit_MotorShield afms = Adafruit_MotorShield(); 
Adafruit_DCMotor *motor = afms.getMotor(1);


boolean last_cmd_pin_state = false;	// The momentary switch on MANUAL_PIN.
time_t  last_cmd_pin_time = 0;		// When it last changed state.
boolean button_state = false;		// The de-bounced version.

int8_t  last_curtain_state = -1;

boolean desired_running = false;	// Whether motor should be on.
boolean desired_opening = false;	// Whether motor should be clockwise.
int8_t  last_motion = CMD_UNKNOWN;	// UNKNOWN, OPEN, CLOSE, ERROR

boolean is_running   = false;		// Whether motor is on.
boolean is_opening   = false;		// Whether motor is clockwise.
boolean blink_state  = false;		// For blinking LEDs.
boolean verbose_tick = false;		// Whether to print a heartbeat.

#define MOTOR_FAST    255
#define MOTOR_SLOW    170
uint8_t motor_speed = MOTOR_FAST;

time_t  last_cmd_start  = 0;		// When the last command began.
time_t  last_cmd_stop   = 0;		// When the last command finished.
time_t  last_on_time    = 0;		// When we last powered on the motor.
time_t  last_off_time   = 0;		// When we last powered off the motor.
time_t  last_blink_time = 0;		// For blinking LEDs.


// Push a char onto the cmd_buffer.
//
static void
buffer_char (char c)
{
  if (c <= 0) return;
  char *s;
  int16_t i;
  for (i = 0, s = cmd_buffer; 
       i < sizeof(cmd_buffer); 
       i++, s++)
    if (!*s) break;
  if (i < sizeof(cmd_buffer)-1) {
    *s++ = c;
    *s = 0;
  } else if (c == '\n' || c == '\r') {
    *cmd_buffer = 0;  // EOL, flush buffer.
  }
}


static void (*reboot) (void) = 0; // Not quite a hardware reset


static void
cmd_flush (void)
{
  Serial.flush();
  if (server_initted && client_initted)
    client.flush();
}


// Need overloaded versions of these, for both real strings and flash strings.

static void
cmd_reply1 (FSTRING s)
{
  Serial.print (s);
  if (server_initted && client_initted)
    client.print (s);
}

static void
cmd_reply1 (const char *s)
{
  Serial.print (s);
  if (server_initted && client_initted)
    client.print (s);
}

static void
cmd_reply (FSTRING s)
{
  cmd_reply1 (s);
  cmd_reply1 (F("\n"));
  cmd_flush();
}

static void
cmd_reply (const char *s)
{
  cmd_reply1 (s);
  cmd_reply1 (F("\n"));
  cmd_flush();
}


// Returns a CMD_ constant, or 0.
//
static int16_t
get_cmd (void)
{
  // Read from both serial and ethernet.  Interleave characters as they
  // arrive into the same buffer, because, who cares.

  while (Serial.available() > 0) {
    buffer_char (Serial.read());
  }

  if (server_initted) {
    if (client_initted) {
      if (client.connected()) {
        while (client.available()) {
          buffer_char (client.read());
        }
      } else {
        //char buf[20];
        //fmt_ip (buf, client.remoteIP());
        client.stop();
        client_initted = false;
        verbose_tick = false;
        cmd_reply(F("-Client disconnected"));
        //cmd_reply1(F("-Client disconnected, IP = "));
        //cmd_reply(buf);
      }
    }
    if (!client_initted) {
      client = server.available();
      if (client.connected()) {
        client_initted = true;
        // Right, because knowing the connected IP isn't something that
        // I might reasonably want to do. Sigh.
        //char buf[20];
        //fmt_ip (buf, Ethernet.remoteIP());
        //cmd_reply1(F("-Client connected, IP = "));
        //cmd_reply(buf);
        cmd_reply(F("-Client connected"));
      }
    }
  }


  // If the cmd_buffer has CR or LF in it, parse the first line and 
  // remove it from the buffer.
  //
  char *s;
  for (s = cmd_buffer; *s; s++) {
    int16_t cmd;
    if (*s == '\r' || *s == '\n') {
      size_t L = s - cmd_buffer;
      if (L == 0)
        cmd = 0;
      else if (L == 4 && !strncasecmp_P (cmd_buffer, PSTR("OPEN"),   L))
        cmd = CMD_OPEN;
      else if (L == 5 && !strncasecmp_P (cmd_buffer, PSTR("CLOSE"),  L))
        cmd = CMD_CLOSE;
      else if (L == 9 && !strncasecmp_P (cmd_buffer, PSTR("OPEN_SLOW"), L))
        cmd = CMD_OPEN_SLOW;
      else if (L == 10 && !strncasecmp_P (cmd_buffer, PSTR("CLOSE_SLOW"), L))
        cmd = CMD_CLOSE_SLOW;
      else if (L == 4 && !strncasecmp_P (cmd_buffer, PSTR("STOP"),   L))
        cmd = CMD_STOP;
      else if (L == 6 && !strncasecmp_P (cmd_buffer, PSTR("TOGGLE"), L))
        cmd = CMD_TOGGLE;
      else if (L == 3 && !strncasecmp_P (cmd_buffer, PSTR("TOG"),    L))
        cmd = CMD_TOGGLE;
      else if (L == 4 && !strncasecmp_P (cmd_buffer, PSTR("TICK"),   L))
        cmd = CMD_TICK;
      else if (L == 5 && !strncasecmp_P (cmd_buffer, PSTR("QUERY"),  L))
        cmd = CMD_QUERY;
      else if (L == 6 && !strncasecmp_P (cmd_buffer, PSTR("STATUS"), L))
        cmd = CMD_QUERY;
      else if (L == 4 && !strncasecmp_P (cmd_buffer, PSTR("STAT"),   L))
        cmd = CMD_QUERY;
      else if (L == 4 && !strncasecmp_P (cmd_buffer, PSTR("HELP"),   L))
        cmd = CMD_HELP;
      else
        cmd = CMD_UNKNOWN;
      memmove ((void *) cmd_buffer, (void *) s+1, (sizeof(cmd_buffer)-L-1));
      cmd_buffer[sizeof(cmd_buffer)-1] = 0;
      return cmd;
    }
  }

  return 0;
}


// Print aaa.bbb.ccc.ddd to the buffer.
static void
fmt_ip (char *out, IPAddress addr)
{
  for (uint8_t i = 0; i < 4; i++) {
    if (i) { *out++ = '.'; *out = 0; }
    itoa (addr[i], out, 10);
    out += strlen(out);
  }
}


// Print mm:ss or h:mm:ss or d:hh:mm:ss to the buffer.
static void
fmt_duration (char *out, uint32_t dur)
{
  dur /= 1000;
  time_t d = (dur / 60  / 60  / 24);
  time_t h = (dur / 60  / 60) % 24;
  time_t m = (dur / 60) % 60;
  time_t s = (dur % 60);
  *out = 0;
  if (d) {
    ultoa (d, out, 10);
    out += strlen(out);
    *out++ = ':'; *out = 0;
  }
  if (d || h) {
    if (d && h < 10) { *out++ = '0'; *out = 0; }
    ultoa (h, out, 10);
    out += strlen(out);
    *out++ = ':'; *out = 0;
  }

  if (d || h || m) {
    if ((d || h) && m < 10) { *out++ = '0'; *out = 0; }
    ultoa (m, out, 10);
    out += strlen(out);
    *out++ = ':'; *out = 0;
  }

  if ((d || h || m) && s < 10) { *out++ = '0'; *out = 0; }
  ultoa (s, out, 10);
}


// Like cmd_reply() but appends duration, idle time and uptime.
//
static void
cmd_reply_duration (FSTRING s, time_t dur, time_t idle, time_t uptime)
{
  char buf[80];
  char *o = buf;
  *o = 0;

  if (dur) {
    strcat_P (o, PSTR(", duration: "));
    o += strlen(o);
    fmt_duration (o, dur);
  }

  if (idle) {
    strcat_P (o, PSTR(", idle: "));
    o += strlen(o);
    fmt_duration (o, idle);
  }

  if (uptime) {
    strcat_P (o, PSTR(", uptime: "));
    o += strlen(o);
    fmt_duration (o, uptime);
  }

  cmd_reply1 (s);
  cmd_reply (buf);
}


// Make some noise by tickling the motor
//
static void
beep(void)
{
  digitalWrite (LED1_PIN, HIGH);
  digitalWrite (LED2_PIN, LOW);
  motor->run(FORWARD);
  delay(100);
  digitalWrite (LED1_PIN, LOW);
  digitalWrite (LED2_PIN, HIGH);
  motor->run(BACKWARD);
  delay(100);
  motor->run(RELEASE);
  digitalWrite (LED1_PIN, LOW);
  digitalWrite (LED2_PIN, LOW);
  delay(100);
}


void
setup (void)
{
  Serial.begin (9600);
  cmd_reply (F("-Hi! I'm the curtain! Hi!"));

  time_t start = millis();

  pinMode (SENSOR1_PIN, INPUT_PULLUP);
  pinMode (SENSOR2_PIN, INPUT_PULLUP);
  pinMode (MANUAL_PIN,  INPUT_PULLUP);
  pinMode (LED1_PIN,    OUTPUT);
  pinMode (LED2_PIN,    OUTPUT);
  digitalWrite (LED1_PIN, LOW);
  digitalWrite (LED2_PIN, LOW);

  afms.begin (1600);  // default frequency
  motor->setSpeed (MOTOR_FAST);

  beep();

# if DEBUG
  cmd_reply (F("-DEBUG MODE"));
# else
  cmd_reply (F("-Requesting DHCP"));
  if (Ethernet.begin (mac) == 0) {
    cmd_reply_duration (F("-DHCP failed"), millis() - start, 0, 0);
  } else {
    char buf[20];
    fmt_ip (buf, Ethernet.localIP());
    cmd_reply1(F("-IP = "));
    cmd_reply1(buf);
    cmd_reply_duration (F(""), millis() - start, 0, 0);

    server = EthernetServer (listen_port);
    server.begin();
    server_initted = true;
  }
# endif

  beep();
  beep();

  last_curtain_state = -1;
  // desired_opening = EEPROM.read (0);

  int16_t i;
  for (i = 0; i < sizeof(cmd_buffer); i++)
    cmd_buffer[i] = 0;

  // Reboot the Arduino if Watchdog.reset() is not called once a second.
//  Watchdog.enable (1000);
}


void
loop (void)
{
  time_t now = millis();
  int8_t cmd = 0;

  // If the momentary switch is pressed and released, interpret it 
  // as CMD_TOGGLE.  But de-bounce it on both ends first.
  //
  {
    boolean cmd_pin_state = !digitalRead (MANUAL_PIN);
    if (cmd_pin_state != last_cmd_pin_state) {
      last_cmd_pin_time = now;
    }

    // Only believe the button state if it has stayed that way for a while.
    //
    if (now - last_cmd_pin_time >= DEBOUNCE_HYSTERESIS) {
      if (button_state && !cmd_pin_state) {
        cmd = CMD_TOGGLE2;  // Gone from "pressed" to "not pressed", debounced.
      }
      button_state = cmd_pin_state;
    }
    last_cmd_pin_state = cmd_pin_state;
  }


  int8_t curtain_state;
  {
    boolean p1 = !digitalRead (SENSOR1_PIN);
    boolean p2 = !digitalRead (SENSOR2_PIN);
    curtain_state = (p1 && p2 ? CURTAIN_ERROR :
                     p1 ? CURTAIN_OPEN :
                     p2 ? CURTAIN_CLOSED :
                     CURTAIN_MIDDLE);
  }

  if (curtain_state != last_curtain_state) {
    cmd_reply_duration ((curtain_state == CURTAIN_OPEN  ? F("-Curtain open")  :
                         curtain_state == CURTAIN_CLOSED? F("-Curtain closed"):
                         curtain_state == CURTAIN_MIDDLE? F("-Curtain middle"):
                         F("-Curtain state unknown")),
                        (is_running
                         ? (time_t) 0
                         : (last_cmd_stop - last_cmd_start)),
                        (time_t) 0,
                        now);
}
  last_curtain_state = curtain_state;


  // If we don't have a command already from the momentary switch,
  // read a textual command from ethernet or the serial port.

  if (! cmd)
    cmd = get_cmd();

  switch (cmd) {
    case 0:
      break;

    case CMD_OPEN:
    case CMD_OPEN_SLOW:
      last_cmd_start = now;
      desired_running = true;
      desired_opening = true;
      motor_speed = (cmd == CMD_OPEN_SLOW ? MOTOR_SLOW : MOTOR_FAST);
      cmd_reply (F("OK"));
      break;

    case CMD_CLOSE:
    case CMD_CLOSE_SLOW:
      last_cmd_start = now;
      desired_running = true;
      desired_opening = false;
      motor_speed = (cmd == CMD_OPEN_SLOW ? MOTOR_SLOW : MOTOR_FAST);
      cmd_reply (F("OK"));
      break;

    case CMD_STOP:
      desired_running = false;
      cmd_reply (F("OK"));
      break;

    case CMD_TOGGLE:
    case CMD_TOGGLE2:
      last_cmd_start = now;
      if (is_running) {					// running -> stop
        desired_running = false;
      } else if (curtain_state == CURTAIN_OPEN) {	// open -> closed
        desired_running = true;
        desired_opening = false;
      } else if (curtain_state == CURTAIN_CLOSED) {	// closed -> open
        desired_running = true;
        desired_opening = true;
      } else { /* curtain_state == CURTAIN_MIDDLE */	// opening -> closing
        desired_running = true;				// closing -> opening
        desired_opening = !desired_opening;
      }
      motor_speed = MOTOR_FAST;
      cmd_reply (cmd == CMD_TOGGLE2 ? F("-Button pressed") : F("OK"));
      break;

    case CMD_TICK:
      verbose_tick = !verbose_tick;
      cmd_reply (F("OK"));
      break;

    case CMD_QUERY:
      {
        FSTRING s1 = 0, *s2 = 0;
        time_t d = (last_cmd_stop - last_cmd_start);

        if (is_running) {
          s1 = (desired_opening ? F("OPENING") : F("CLOSING"));
          d = now - last_cmd_start;
        } else if (curtain_state == CURTAIN_OPEN)
          s1 = F("OPEN");
        else if (curtain_state == CURTAIN_CLOSED)
          s1 = F("CLOSED");
        else if (curtain_state == CURTAIN_MIDDLE)
          s1 = F("MIDDLE");
        else
          s1 = F("SENSOR ERROR");

        switch (last_motion) {
        case CMD_UNKNOWN:    s2 = F("just booted");     break;
        case CURTAIN_ERROR:  s2 = F("emergency stop!"); break;
        case CURTAIN_OPEN:   s2 = F("was opening");     break;
        case CURTAIN_CLOSED: s2 = F("was closing");     break;
        default:             s2 = F("INTERNAL ERROR");  break;
        }

        if (is_running) {
          cmd_reply_duration (s1, d, (time_t) 0, now);
        } else {
          cmd_reply1 (s1);
          cmd_reply1 (F(", "));
          cmd_reply_duration (s2, d, now - last_cmd_stop, now);
        }
      }
      break;

    case CMD_HELP:
      cmd_reply (F("OPEN, CLOSE, STOP, TOGGLE, QUERY, HELP"));
      break;

    default:
      cmd_reply (F("UNKNOWN COMMAND"));
      break;
  }


  // If the motor has been on for an unreasonably long time,
  // assume there's a physical problem, and shut it off.
  //
  if (is_running &&
      (now - last_on_time) / 1000 >=
      (MAX_RUNTIME * (motor_speed == MOTOR_FAST ? 1 : 3))) {
    cmd_reply_duration (F("-Running too long, emergency stop"),
                        (now - last_on_time), (time_t) 0, now);
    desired_running = false;
    last_cmd_stop = now;
    last_motion = CURTAIN_ERROR;
  }


  if (desired_running) {
    if (desired_opening && curtain_state == CURTAIN_OPEN) {
      cmd_reply_duration (F("-Done opening"),
                          (now - last_cmd_start), (time_t) 0, now);
      desired_running = false;  // done opening
      last_cmd_stop = now;

    } else if (!desired_opening && curtain_state == CURTAIN_CLOSED) {
      cmd_reply_duration (F("-Done closing"),
                          (now - last_cmd_start), (time_t) 0, now);
      desired_running = false;  // done closing
      last_cmd_stop = now;
    }
  }

  if (is_running && !desired_running) {

    // Request has been made to turn off the motor, when it was on.
    // Do so immediately.

    last_off_time = now;
    is_running = false;
    last_cmd_stop = now;
    cmd_reply_duration (F("-Stopping now"), 
                        (now - last_cmd_start), (time_t) 0, now);

    // The device keeps resetting randomly, shortly after it has completed
    // one or two cycles.  So, fuck it, just reboot after turning off the
    // motor.  In order to make TOGGLE work, we have to save 'desired_opening'
    // into EEPROM to make it persist across reboots.  Alternately: don't
    // reboot for the TOGGLE command. Or alternately alternately: use a
    // watchdog timer.
    //
/*
    if (! (cmd == CMD_TOGGLE || cmd == CMD_TOGGLE2)) {
      // EEPROM.update (0, desired_opening);
      cmd_reply (F("REBOOTING"));
      delay (500);
      reboot();
    }
*/

  } else if (!is_running && desired_running) {

    // Request has been made to turn on the motor, when it was off.
    // Do so only if it has been off for long enough.

    if (now - last_off_time >= MOTOR_HYSTERESIS) {
      last_on_time = now;
      is_running = true;
      is_opening = desired_opening;
      last_motion = (is_opening ? CURTAIN_OPEN : CURTAIN_CLOSED);
      motor->setSpeed (motor_speed);

      cmd_reply_duration ((desired_opening
                           ? F("-Opening now")
                           : F("-Closing now")),
                          (time_t) 0, (time_t) 0, now);
    } else {
      cmd_reply (F("-Starting momentarily"));
    }

  } else if (is_running && desired_opening != is_opening) {

    // Request has been made to reverse the direction of the motor while on.
    // Turn it off immediately, then wait.  The next time through the loop,
    // this will look like "request to turn motor on".

    last_off_time = now;
    is_running = false;
    cmd_reply (F("-Stopping now, reversing momentarily"));

  } else {
    is_running = desired_running;
    is_opening = desired_opening;
  }


  // Flush is_running and is_opening down into the hardware.

  if (!is_running) {
    motor->run(RELEASE);
  } else if (is_opening) {
    motor->run(BACKWARD);
  } else {  // is_closing
    // counter clockwise.
    motor->run(FORWARD);
  }


  // Light up the LEDs to say what's what.
  // Fun fact: both of them can't be lit at the same time.
  // I don't understand why. Possibly I wired them stupidly.

  if (is_running) {
    // While running, <blink> with a milspec 3:1 duty cycle.
    int16_t tick = (is_opening ? 750 : 250);
    if (blink_state && now - last_blink_time >= tick) {
      blink_state = false;
      last_blink_time = now;
    } else if (!blink_state && now - last_blink_time > 1000-tick) {
      blink_state = true;
      last_blink_time = now;
    }
    digitalWrite (LED1_PIN, (blink_state ? HIGH : LOW));
    digitalWrite (LED2_PIN, (blink_state ? LOW : HIGH));

    if (verbose_tick && last_blink_time == now)
      cmd_reply_duration ((blink_state ? F("-tick") : F("-tock")),
                          (time_t) 0, (time_t) 0, now);

  } else if (curtain_state == CURTAIN_MIDDLE) {
    digitalWrite (LED1_PIN, LOW);
    digitalWrite (LED2_PIN, LOW);
  } else if (curtain_state == CURTAIN_OPEN) {
    digitalWrite (LED1_PIN, HIGH);
    digitalWrite (LED2_PIN, LOW);
  } else if (curtain_state == CURTAIN_CLOSED) {
    digitalWrite (LED1_PIN, LOW);
    digitalWrite (LED2_PIN, HIGH);
  } else {  // (curtain_state == CURTAIN_ERROR)
    int16_t tick = 250;
    if (blink_state && now - last_blink_time >= tick) {
      blink_state = false;
      last_blink_time = now;
    } else if (!blink_state && now - last_blink_time > 500-tick) {
      blink_state = true;
      last_blink_time = now;
    }

    if (verbose_tick && last_blink_time == now)
      cmd_reply_duration ((blink_state ? F("-TICK") : F("-TOCK")),
                          (time_t) 0, (time_t) 0, now);

    digitalWrite (LED1_PIN, (blink_state ? HIGH : LOW));
    digitalWrite (LED2_PIN, (blink_state ? LOW : HIGH));
  }

  if (verbose_tick && !is_running && !desired_running) {
    if (now - last_blink_time >= 1000) {
      cmd_reply_duration (F("-idle"), (time_t) 0, (time_t) 0, now);
      last_blink_time = now;
    }
  }

//  Watchdog.reset();   // I'm not dead yet!
}
