#include "thread_pool.h"

ThreadPool::ThreadPool(size_t threads) : stop(false) {
    for (size_t i = 0; i < threads; ++i) {
        workers.emplace_back([this] {
            while (true) {
                std::function<void()> task; // ���ڴ洢��ִ�е�����
                {
                    // ʹ�� unique_lock �Զ����������ļ����ͽ���
                    std::unique_lock<std::mutex> lock(queue_mutex);
                    condition.wait(lock, [this] {
                        return stop || !tasks.empty();// continue until return true
                        });
                    if (stop && tasks.empty()) {
                        return;
                    }
                    task = std::move(tasks.front());
                    tasks.pop();
                } // ����������������Զ�����
                task();
            }
            });
    }
}

ThreadPool::~ThreadPool() {
    {
        std::unique_lock<std::mutex> lock(queue_mutex);
        stop = true;
    } 

    // �������еȴ��е��̣߳������Ǽ�� stop ��־���˳�ѭ��
    condition.notify_all();

    for (std::thread& worker : workers) {
        worker.join();
    }
}

// ��������񵽶���
void ThreadPool::enqueue(std::function<void()> task) {
    {
        std::unique_lock<std::mutex> lock(queue_mutex);
        if (stop) {
            return;
        }
        tasks.emplace(task);
    } 

    condition.notify_one();
}