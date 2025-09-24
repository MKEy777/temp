#include <vector>
#include "select_demultiplexer.h" 
#include "event_handler.h"
#include <sys/select.h> 

SelectDemultiplexer::SelectDemultiplexer() {   // ≥ı ºªØ fd_set
    FD_ZERO(&read_set);
    FD_ZERO(&write_set);
    FD_ZERO(&err_set);
}

int SelectDemultiplexer::wait_event(std::map<Handle, EventHandler*>& handlers, int timeout) {
    fd_set temp_read = read_set;
    fd_set temp_write = write_set;
    fd_set temp_err = err_set;

    timeval tv = { timeout / 1000, (timeout % 1000) * 1000 };

    int max_fd = 0;
    if (!handlers.empty()) {
        max_fd = handlers.rbegin()->first;
    }

    int num_events = select(max_fd + 1, &temp_read, &temp_write, &temp_err, timeout == 0 ? nullptr : &tv);
    if (num_events > 0) {
        auto handlers_copy = handlers;
        for (auto const& [fd, handler] : handlers_copy) {
            if (FD_ISSET(fd, &temp_read)) handler->handle_read();
            if (FD_ISSET(fd, &temp_write)) handler->handle_write();
            if (FD_ISSET(fd, &temp_err)) handler->handle_error();
        }
    }
    return num_events;
}

bool SelectDemultiplexer::regist(Handle handle, Event evt) {
    if (evt & READ) FD_SET(handle, &read_set);
    if (evt & WRITE) FD_SET(handle, &write_set);
    FD_SET(handle, &err_set);
    return true;
}

bool SelectDemultiplexer::remove(Handle handle) {
    FD_CLR(handle, &read_set);
    FD_CLR(handle, &write_set);
    FD_CLR(handle, &err_set);
    return true;
}