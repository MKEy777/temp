#include <winsock2.h>
#include <vector>
#include "event_demultiplexer.h"
#include "event_handler.h"

class SelectDemultiplexer : public EventDemultiplexer {
private:
    fd_set read_set;
    fd_set write_set;
    fd_set err_set;

public:
    SelectDemultiplexer() {
        FD_ZERO(&read_set);
        FD_ZERO(&write_set);
        FD_ZERO(&err_set);
    }

    int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout) override {
        fd_set temp_read = read_set;
        fd_set temp_write = write_set;
        fd_set temp_err = err_set;

        timeval tv = { timeout / 1000, (timeout % 1000) * 1000 };

        int max_fd = 0;
        for (auto& pair : handlers) {
            if ((int)pair.first > max_fd) max_fd = (int)pair.first;
        }

        int num_events = select(max_fd + 1, &temp_read, &temp_write, &temp_err, timeout == 0 ? nullptr : &tv);
        if (num_events > 0) {
            for (auto& pair : handlers) {
                Handle fd = pair.first;
                if (FD_ISSET(fd, &temp_read)) pair.second->handle_read();
                if (FD_ISSET(fd, &temp_write)) pair.second->handle_write();
                if (FD_ISSET(fd, &temp_err)) pair.second->handle_error();
            }
        }
        return num_events;
    }

    bool regist(Handle handle, Event evt) override {
        if (evt & READ) FD_SET(handle, &read_set);
        if (evt & WRITE) FD_SET(handle, &write_set);
        FD_SET(handle, &err_set);
        return true;
    }

    bool remove(Handle handle) override {
        FD_CLR(handle, &read_set);
        FD_CLR(handle, &write_set);
        FD_CLR(handle, &err_set);
        return true;
    }
};