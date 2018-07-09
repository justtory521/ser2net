/*
 *  ser2net - A program for allowing telnet connection to serial ports
 *  Copyright (C) 2018  Corey Minyard <minyard@acm.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

%module genio

%{
#include <string.h>
#include <termios.h>
#include <sgtty.h>
#include "genio/genio.h"
#include "genio/sergenio.h"
#include "utils/selector.h"
#include "utils/waiter.h"

/*
 * If an exception occurs inside a waiter, we want to stop the wait
 * operation and propagate back.  So we wake it up
 */
static struct waiter_s *curr_waiter;

#include "genio_python.h"

static struct selector_s *genio_sel;

static void setup_genio_sel(void)
{
    if (!genio_sel)
	sel_alloc_selector_nothread(&genio_sel);
}

static int
genio_do_wait(struct waiter_s *waiter, struct timeval *timeout)
{
    int err;
    struct waiter_s *prev_waiter = curr_waiter;

    curr_waiter = waiter;
    do {
	err = wait_for_waiter_timeout_intr(waiter, 1, timeout);
	if (check_for_err()) {
	    if (prev_waiter)
		wake_waiter(prev_waiter);
	    break;
	}
	if (err == EINTR)
	    continue;
	break;
    } while (1);
    curr_waiter = prev_waiter;

    return err;
}

void get_random_bytes(char **rbuffer, size_t *rbuffer_len, int size_to_allocate)
{
    char *buffer;
    int i;

    buffer = malloc(size_to_allocate);
    if (!buffer) {
	*rbuffer = NULL;
	*rbuffer_len = 0;
	return;
    }
    srandom(time(NULL));

    for (i = 0; i < size_to_allocate; i++)
	buffer[i] = random();
    *rbuffer = buffer;
    *rbuffer_len = size_to_allocate;
}

/* Defined in another file to avoid string type collisions. */
extern int remote_termios(struct termios *termios, int fd);
extern int set_remote_mctl(unsigned int mctl, int fd);
extern int set_remote_sererr(unsigned int err, int fd);
extern int set_remote_null_modem(bool val, int fd);
extern int get_remote_mctl(unsigned int *mctl, int fd);
extern int get_remote_sererr(unsigned int *err, int fd);
extern int get_remote_null_modem(int *val, int fd);

%}

%include <typemaps.i>
%include <exception.i>

%include "genio_python.i"

%nodefaultctor sergenio;
struct genio { };
struct sergenio { };
struct genio_acceptor { };
struct waiter_s { };

%extend genio {
    genio(char *str, int max_read_size, swig_cb *handler) {
	int rv;
	struct genio_data *data;
	struct genio *io = NULL;

	setup_genio_sel();

	data = malloc(sizeof(*data));
	if (!data)
	    return NULL;

	data->handler_val = ref_swig_cb(handler, read_callback);

	rv = str_to_genio(str, genio_sel, max_read_size, &gen_cbs,
			  data, &io);
	if (rv) {
	    deref_swig_cb_val(data->handler_val);
	    free(data);
	}
			  
	return io;
    }

    ~genio()
    {
	struct genio_data *data = genio_get_user_data(self);

	genio_free(self);
	deref_swig_cb_val(data->handler_val);
	free(data);
    }

    %rename (remote_id) remote_idt;
    int remote_idt() {
	int remid;

	err_handle("remote_id", genio_remote_id(self, &remid));
	return remid;
    }
    %rename(open) opent;
    void opent() {
	err_handle("open", genio_open(self));
    }

    %rename(close) closet;
    void closet(swig_cb *done) {
	swig_cb_val *done_val = NULL;
	void (*close_done)(struct genio *io, void *cb_data) = NULL;
	int rv;
	
	if (!nil_swig_cb(done)) {
	    close_done = genio_close_done;
	    done_val = ref_swig_cb(done, close_done);
	}
	rv = genio_close(self, close_done, done_val);
	if (rv && done_val)
	    deref_swig_cb_val(done_val);

	err_handle("close", rv);
    }

    %rename(write) writet;
    %apply (char *STRING, size_t LENGTH) { (char *str, size_t len) };
    unsigned int writet(char *str, size_t len) {
	unsigned int wr = 0;
	int rv;

	rv = genio_write(self, &wr, str, len);
	err_handle("write", rv);
	return wr;
    }

    void read_cb_enable(bool enable) {
	genio_set_read_callback_enable(self, enable);
    }

    void write_cb_enable(bool enable) {
	genio_set_write_callback_enable(self, enable);
    }

    %newobject cast_to_sergenio;
    struct sergenio *cast_to_sergenio() {
	struct sergenio *rv = genio_to_sergenio(self);

	if (!rv)
	    cast_error("sergenio", "genio");
	return rv;
    }
}

%define sgenio_entry(name)
    void sg_##name(int name, swig_cb *h) {
	struct sergenio_cbdata *cbdata = NULL;
	int rv;

	if (!nil_swig_cb(h)) {
	    cbdata = sergenio_cbdata(name, h);
	    if (!cbdata) {
		oom_err();
		return;
	    }
	    rv = sergenio_##name(self, name, sergenio_cb, cbdata);
	} else {
	    rv = sergenio_##name(self, name, NULL, NULL);
	}

	if (rv && cbdata)
	    cleanup_sergenio_cbdata(cbdata);
	ser_err_handle("sg_"stringify(name), rv);
    }

    int sg_##name##_s(int name) {
	struct sergenio_b *b = NULL;
	int rv;

	rv = sergenio_b_alloc(self, genio_sel, 0, &b);
	if (!rv)
	    rv = sergenio_##name##_b(b, &name);
	if (rv)
	    ser_err_handle("sg_"stringify(name)"_s", rv);
	if (b)
	    sergenio_b_free(b);
	return name;
    }
%enddef

%constant int SERGENIO_PARITY_NONE = SERGENIO_PARITY_NONE;
%constant int SERGENIO_PARITY_ODD = SERGENIO_PARITY_ODD;
%constant int SERGENIO_PARITY_EVEN = SERGENIO_PARITY_EVEN;
%constant int SERGENIO_PARITY_MARK = SERGENIO_PARITY_MARK;
%constant int SERGENIO_PARITY_SPACE = SERGENIO_PARITY_SPACE;

%constant int SERGENIO_FLOWCONTROL_NONE = SERGENIO_FLOWCONTROL_NONE;
%constant int SERGENIO_FLOWCONTROL_XON_XOFF = SERGENIO_FLOWCONTROL_XON_XOFF;
%constant int SERGENIO_FLOWCONTROL_RTS_CTS = SERGENIO_FLOWCONTROL_RTS_CTS;

%constant int SERGENIO_BREAK_ON = SERGENIO_BREAK_ON;
%constant int SERGENIO_BREAK_OFF = SERGENIO_BREAK_OFF;

%constant int SERGENIO_DTR_ON = SERGENIO_DTR_ON;
%constant int SERGENIO_DTR_OFF = SERGENIO_DTR_OFF;

%constant int SERGENIO_RTS_ON = SERGENIO_RTS_ON;
%constant int SERGENIO_RTS_OFF = SERGENIO_RTS_OFF;

/* For get/set modem control. */
%constant int SERGENIO_TIOCM_CAR = TIOCM_CAR;
%constant int SERGENIO_TIOCM_CTS = TIOCM_CTS;
%constant int SERGENIO_TIOCM_DSR = TIOCM_DTR;
%constant int SERGENIO_TIOCM_RNG = TIOCM_RNG;

/* For remote errors.  These are the kernel numbers. */
%constant int SERGENIO_TTY_BREAK = 1 << 1;
%constant int SERGENIO_TTY_FRAME = 1 << 2;
%constant int SERGENIO_TTY_PARITY = 1 << 3;
%constant int SERGENIO_TTY_OVERRUN = 1 << 4;

%extend sergenio {
    %newobject cast_to_genio;
    struct genio *cast_to_genio() {
	return sergenio_to_genio(self);
    }

    /* Standard baud rates. */
    sgenio_entry(baud);

    /* 5, 6, 7, or 8 bits. */
    sgenio_entry(datasize);

    /* SERGENIO_PARITY_ entries */
    sgenio_entry(parity);

    /* 1 or 2 */
    sgenio_entry(stopbits);

    /* SERGENIO_FLOWCONTROL_ entries */
    sgenio_entry(flowcontrol);

    /* SERGENIO_BREAK_ entries */
    sgenio_entry(sbreak);

    /* SERGENIO_DTR_ entries */
    sgenio_entry(dtr);

    /* SERGENIO_RTS_ entries */
    sgenio_entry(rts);

    /*
     * From here down get and set the serialsim driver special commands
     * for remote termios and modem line handling.  See the driver for
     * details.
     */

    /*
     * Get remote termios.  For Python, this matches what the termios
     * module does.
     */
    void get_remote_termios(void *termios) {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = remote_termios(termios, fd);

	if (rv)
	    err_handle("get_remote_termios", rv);
    }

    void set_remote_modem_ctl(unsigned int val) {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = set_remote_mctl(val, fd);

	if (rv)
	    err_handle("set_remote_modem_ctl", rv);
    }

    unsigned int get_remote_modem_ctl() {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv;
	unsigned int val;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = get_remote_mctl(&val, fd);

	if (rv)
	    err_handle("get_remote_modem_ctl", rv);

	return val;
    }

    void set_remote_serial_err(unsigned int val) {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = set_remote_sererr(val, fd);

	if (rv)
	    err_handle("set_remote_serial_err", rv);
    }


    unsigned int get_remote_serial_err() {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv;
	unsigned int val;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = get_remote_sererr(&val, fd);

	if (rv)
	    err_handle("get_remote_serial_err", rv);

	return val;
    }

    void set_remote_null_modem(bool val) {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = set_remote_null_modem(val, fd);

	if (rv)
	    err_handle("set_remote_null_modem", rv);
    }

    bool get_remote_null_modem() {
	struct genio *io = sergenio_to_genio(self);
	int fd, rv, val;

	rv = genio_remote_id(io, &fd);
	if (!rv)
	    rv = get_remote_null_modem(&val, fd);

	if (rv)
	    err_handle("get_remote_null_modem", rv);

	return val;
    }
}

%extend genio_acceptor {
    genio_acceptor(char *str, int max_read_size, swig_cb *handler) {
	struct genio_acc_data *data;
	struct genio_acceptor *acc;
	int rv;

	setup_genio_sel();

	data = malloc(sizeof(*data));
	if (!data)
	    return NULL;

	data->handler_val = ref_swig_cb(handler, new_connection);

	rv = str_to_genio_acceptor(str, genio_sel, max_read_size, &gen_acc_cbs,
			  data, &acc);
	if (rv) {
	    deref_swig_cb_val(data->handler_val);
	    free(data);
	}

	return acc;
    }

    ~genio_acceptor()
    {
	struct genio_acc_data *data = genio_acceptor_get_user_data(self);

	genio_acc_free(self);
	deref_swig_cb_val(data->handler_val);
	free(data);
    }

    void shutdown(swig_cb *done) {
	swig_cb_val *done_val = NULL;
	int rv;

	if (!nil_swig_cb(done))
	    done_val = ref_swig_cb(done, shutdown);
	rv = genio_acc_shutdown(self, genio_acc_shutdown_done, done_val);
	if (rv && done_val)
	    deref_swig_cb_val(done_val);

	err_handle("shutdown", rv);
    }
}

%extend waiter_s {
    waiter_s() {
	setup_genio_sel();
	return alloc_waiter(genio_sel, 0);
    }

    ~waiter_s() {
	free_waiter(self);
    }

    int wait_timeout(int timeout) {
	struct timeval tv = { timeout / 1000, timeout % 1000 };

	return genio_do_wait(self, &tv);
    }

    void wait() {
	genio_do_wait(self, NULL);
    }

    void wake() {
	wake_waiter(self);
    }
}

/* Get a bunch of random bytes. */
void get_random_bytes(char **rbuffer, size_t *rbuffer_len,
		      int size_to_allocate);
