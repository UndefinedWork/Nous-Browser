// Read-only, unprivileged macOS process-tree sampler. No argv/path/URL reads.
// Build: xcrun clang++ -std=c++20 -O2 -Wall -Wextra -Werror \
//   Scripts/sample-browser-processes.cpp -o .build/sample-browser-processes
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iomanip>
#include <iostream>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
mach_timebase_info_data_t timebase{};
uint64_t nanoseconds(uint64_t ticks) {
  return static_cast<uint64_t>((static_cast<__uint128_t>(ticks) * timebase.numer) / timebase.denom);
}
uint64_t processCPUClock() {
  timespec value{};
  if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)) throw std::runtime_error("CPU clock unavailable");
  return static_cast<uint64_t>(value.tv_sec) * 1000000000ULL + value.tv_nsec;
}
std::string quote(const std::string& value) {
  std::ostringstream out; out << '"';
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<unsigned>(c) << std::dec;
    else out << c;
  }
  out << '"'; return out.str();
}
struct Birth {
  uint64_t sec{}, usec{};
  bool operator==(const Birth&) const = default;
};
struct Observation {
  pid_t pid{}, ppid{}; Birth birth{}; uid_t uid{};
  rusage_info_v4 usage{};
  uint64_t observedTicks{};
};
struct ReadResult { std::optional<Observation> value; int error{}; std::string stage; };
ReadResult readProcess(pid_t pid) {
  proc_bsdinfo before{}, after{};
  errno = 0;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before))
    return {{}, errno ? errno : ESRCH, "identity-before"};
  Observation observation;
  errno = 0;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, reinterpret_cast<rusage_info_t*>(&observation.usage)) != 0)
    return {{}, errno ? errno : EIO, "rusage"};
  // Timestamp each read, not the beginning of an arbitrarily long tree scan.
  observation.observedTicks = mach_absolute_time();
  errno = 0;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after))
    return {{}, errno ? errno : ESRCH, "identity-after"};
  if (before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec)
    return {{}, EAGAIN, "identity-changed-during-read"};
  observation.pid = pid; observation.ppid = after.pbi_ppid; observation.uid = after.pbi_uid;
  observation.birth = {after.pbi_start_tvsec, after.pbi_start_tvusec};
  return {observation, 0, {}};
}
bool sameProcess(const Observation& a, const Observation& b) {
  return a.pid == b.pid && a.birth == b.birth &&
         a.usage.ri_proc_start_abstime == b.usage.ri_proc_start_abstime;
}
std::string identity(const Observation& value) {
  return std::to_string(value.pid) + ":" + std::to_string(value.birth.sec) + ":" +
         std::to_string(value.birth.usec) + ":" + std::to_string(value.usage.ri_proc_start_abstime);
}
std::vector<pid_t> children(pid_t pid, bool& failed, bool& truncated) {
  failed = false; truncated = false;
  std::vector<pid_t> pids(64);
  for (int attempt = 0; attempt < 8; ++attempt) {
    errno = 0;
    // The wrapper accepts a byte-sized buffer but returns a PID count, unlike
    // proc_listpids. See Apple's libproc.c implementation.
    const int count = proc_listchildpids(pid, pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (count < 0 || (count == 0 && errno != 0)) { failed = true; return {}; }
    if (static_cast<size_t>(count) < pids.size()) {
      pids.resize(count); return pids;
    }
    pids.resize(pids.size() * 2);
  }
  truncated = true; return {};
}
struct Tracked {
  Observation last;
  bool retired = false;
  bool missedLast = false;
  size_t misses = 0;
};
struct Summary {
  std::set<pid_t> seen;
  std::set<std::string> generations;
  size_t samples{}, reparentings{}, exits{}, omissions{}, enumerationsFailed{};
  uint64_t cpuNsObserved{};
};
struct Collector {
  pid_t root;
  std::map<pid_t, Tracked> tracked;
  Summary summary;
  std::function<void(const std::string&)> emit;
  uint64_t startedTicks{}, previousTicks{};
  host_cpu_load_info_data_t previousHost{};
  bool hasHost = false;
  Collector(pid_t pid, std::function<void(const std::string&)> writer) : root(pid), emit(std::move(writer)) {
    auto first = readProcess(root);
    if (!first.value) throw std::runtime_error("Cannot sample root PID without additional privileges; errno=" + std::to_string(first.error));
    if (first.value->uid != geteuid()) throw std::runtime_error("Root PID must belong to the current user");
    tracked.emplace(root, Tracked{*first.value}); summary.seen.insert(root);
    summary.generations.insert(identity(*first.value));
    startedTicks = previousTicks = mach_absolute_time();
    emit("{\"type\":\"metadata\",\"schema\":1,\"root_pid\":" + std::to_string(root) +
         ",\"root_identity\":" + quote(identity(*first.value)) +
         ",\"cpu_raw_unit\":\"mach_absolute_ticks\",\"timebase_numer\":" + std::to_string(timebase.numer) +
         ",\"timebase_denom\":" + std::to_string(timebase.denom) +
         ",\"cpu_percent_100_means\":\"one_logical_core\",\"no_argv_or_page_content\":true,"
         "\"limitations\":[\"Polling can miss short-lived or already-reparented undiscovered descendants\","
         "\"Exit CPU after the last readable sample can be missing\",\"Shared RSS can be double-counted\","
         "\"GPU process CPU is included; GPU utilization and network traffic bytes are not measured\"]}");
  }
  void event(const std::string& kind, pid_t pid, const std::string& extra = {}) {
    emit("{\"type\":\"event\",\"event\":" + quote(kind) + ",\"pid\":" + std::to_string(pid) +
         ",\"elapsed_ns\":" + std::to_string(nanoseconds(mach_absolute_time() - startedTicks)) + extra + "}");
  }
  void sample() {
    const auto cycleStart = mach_absolute_time();
    std::map<pid_t, Observation> observations;
    bool complete = true;
    size_t omitted = 0;
    // Sample previously observed children independently of PPID. They remain
    // part of this tree after reparenting, but never after PID-generation reuse.
    for (auto& [pid, record] : tracked) {
      if (record.retired) continue;
      auto read = readProcess(pid);
      if (!read.value) {
        ++summary.omissions; ++omitted; ++record.misses; record.missedLast = true; complete = false;
        event("sample-unavailable", pid, ",\"errno\":" + std::to_string(read.error) + ",\"stage\":" + quote(read.stage));
        if (read.error == ESRCH) {
          record.retired = true; ++summary.exits;
          event("exit-observed-final-counters-unavailable", pid, ",\"identity\":" + quote(identity(record.last)));
        }
        continue;
      }
      if (!sameProcess(record.last, *read.value)) {
        record.retired = true; complete = false; ++summary.exits;
        event("pid-reused-excluded", pid, ",\"old_identity\":" + quote(identity(record.last)));
        continue;
      }
      if (read.value->ppid != record.last.ppid) {
        ++summary.reparentings;
        event("reparented-still-tracked", pid, ",\"old_ppid\":" + std::to_string(record.last.ppid) +
              ",\"new_ppid\":" + std::to_string(read.value->ppid));
      }
      observations.emplace(pid, *read.value);
    }
    // Breadth-first discovery follows only verified current parent identities.
    std::vector<pid_t> queue;
    for (const auto& [pid, observation] : observations) {
      if (!observation.usage.ri_proc_exit_abstime) queue.push_back(pid);
    }
    for (size_t index = 0; index < queue.size(); ++index) {
      pid_t parent = queue[index]; bool failed, truncated;
      auto found = children(parent, failed, truncated);
      if (failed || truncated) {
        complete = false; ++summary.enumerationsFailed;
        event(truncated ? "child-list-truncated" : "child-list-unavailable", parent); continue;
      }
      auto parentAfter = readProcess(parent);
      if (!parentAfter.value || !sameProcess(observations.at(parent), *parentAfter.value)) {
        complete = false; ++summary.enumerationsFailed;
        event("parent-changed-during-discovery", parent); continue;
      }
      for (pid_t child : found) {
        if (child <= 0 || observations.contains(child)) continue;
        auto childRead = readProcess(child);
        if (!childRead.value || childRead.value->ppid != parent) {
          complete = false; ++summary.omissions;
          event("child-discovery-race-or-unavailable", child); continue;
        }
        const auto& value = *childRead.value;
        if (value.usage.ri_proc_start_abstime < observations.at(parent).usage.ri_proc_start_abstime) {
          complete = false; event("child-birth-precedes-parent-excluded", child); continue;
        }
        auto old = tracked.find(child);
        if (old != tracked.end() && !old->second.retired) continue;
        tracked.insert_or_assign(child, Tracked{value});
        observations.emplace(child, value); queue.push_back(child); summary.seen.insert(child);
        summary.generations.insert(identity(value));
        event("descendant-discovered", child, ",\"ppid\":" + std::to_string(parent) + ",\"identity\":" + quote(identity(value)));
      }
    }
    uint64_t cpuNs = 0, footprint = 0, rss = 0, reads = 0, writes = 0, pageins = 0, wakeups = 0, idleWakeups = 0;
    size_t alive = 0;
    std::ostringstream rows;
    bool separator = false;
    for (const auto& [pid, current] : observations) {
      auto& record = tracked.at(pid);
      const auto& prior = record.last;
      const auto& now = current.usage;
      const auto& old = prior.usage;
      // A first observation is a baseline. Record its counters but do not
      // retroactively attribute unknown pre-discovery work to this interval.
      bool baseline = current.observedTicks == prior.observedTicks;
      bool regressed = now.ri_user_time < old.ri_user_time || now.ri_system_time < old.ri_system_time;
      bool usable = !baseline && !regressed;
      if (baseline || record.missedLast || regressed) complete = false;
      auto delta = [usable](uint64_t a, uint64_t b) { return usable && a >= b ? a - b : 0; };
      uint64_t userNs = nanoseconds(delta(now.ri_user_time, old.ri_user_time));
      uint64_t systemNs = nanoseconds(delta(now.ri_system_time, old.ri_system_time));
      uint64_t elapsed = nanoseconds(current.observedTicks - prior.observedTicks);
      cpuNs += userNs + systemNs;
      reads += delta(now.ri_diskio_bytesread, old.ri_diskio_bytesread);
      writes += delta(now.ri_diskio_byteswritten, old.ri_diskio_byteswritten);
      pageins += delta(now.ri_pageins, old.ri_pageins);
      wakeups += delta(now.ri_interrupt_wkups, old.ri_interrupt_wkups);
      idleWakeups += delta(now.ri_pkg_idle_wkups, old.ri_pkg_idle_wkups);
      if (!now.ri_proc_exit_abstime) { ++alive; footprint += now.ri_phys_footprint; rss += now.ri_resident_size; }
      if (separator) rows << ','; separator = true;
      rows << "{\"pid\":" << pid << ",\"ppid\":" << current.ppid << ",\"identity\":" << quote(identity(current))
           << ",\"baseline\":" << (baseline ? "true" : "false") << ",\"coverage_gap\":" << (record.missedLast ? "true" : "false")
           << ",\"observation_elapsed_ns\":" << nanoseconds(current.observedTicks - startedTicks)
           << ",\"interval_ns\":" << elapsed << ",\"cpu_user_delta_ns\":" << userNs << ",\"cpu_system_delta_ns\":" << systemNs
           << ",\"cpu_percent_one_core\":";
      if (usable && elapsed) rows << (100.0 * (userNs + systemNs) / elapsed); else rows << "null";
      rows << ",\"cpu_user_raw_ticks\":" << now.ri_user_time << ",\"cpu_system_raw_ticks\":" << now.ri_system_time
           << ",\"physical_footprint_bytes\":" << now.ri_phys_footprint << ",\"rss_bytes\":" << now.ri_resident_size
           << ",\"disk_read_bytes\":" << now.ri_diskio_bytesread << ",\"disk_write_bytes\":" << now.ri_diskio_byteswritten
           << ",\"logical_write_bytes\":" << now.ri_logical_writes << ",\"pageins\":" << now.ri_pageins
           << ",\"interrupt_wakeups\":" << now.ri_interrupt_wkups << ",\"package_idle_wakeups\":" << now.ri_pkg_idle_wkups
           << ",\"exited\":" << (now.ri_proc_exit_abstime ? "true" : "false") << '}';
      record.last = current; record.missedLast = false;
      if (now.ri_proc_exit_abstime) {
        record.retired = true; ++summary.exits;
        event("exit-observed-final-counters-read", pid, ",\"identity\":" + quote(identity(current)));
      }
    }
    const auto cycleEnd = mach_absolute_time();
    uint64_t interval = nanoseconds(cycleEnd - previousTicks);
    double loads[3]{}; int loadCount = getloadavg(loads, 3);
    host_cpu_load_info_data_t host{}; mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    auto hostPort = mach_host_self();
    bool hostOK = host_statistics(hostPort, HOST_CPU_LOAD_INFO, reinterpret_cast<host_info_t>(&host), &count) == KERN_SUCCESS;
    mach_port_deallocate(mach_task_self(), hostPort);
    std::ostringstream line;
    line << std::setprecision(10) << "{\"type\":\"sample\",\"index\":" << summary.samples++
         << ",\"elapsed_ns\":" << nanoseconds(cycleEnd - startedTicks) << ",\"interval_ns\":" << interval
         << ",\"collection_duration_ns\":" << nanoseconds(cycleEnd - cycleStart)
         << ",\"known_processes\":" << tracked.size() << ",\"alive_observed\":" << alive << ",\"omitted_this_sample\":" << omitted
         << ",\"observed_interval_complete\":" << (complete ? "true" : "false")
         << ",\"cpu_delta_ns_observed\":" << cpuNs << ",\"cpu_percent_one_core\":";
    if (complete && interval) line << 100.0 * cpuNs / interval; else line << "null";
    line << ",\"physical_footprint_bytes\":" << footprint << ",\"rss_bytes\":" << rss
         << ",\"disk_read_delta_bytes\":" << reads << ",\"disk_write_delta_bytes\":" << writes
         << ",\"pageins_delta\":" << pageins << ",\"interrupt_wakeups_delta\":" << wakeups
         << ",\"package_idle_wakeups_delta\":" << idleWakeups << ",\"system_load_average\":[";
    for (int i = 0; i < loadCount; ++i) { if (i) line << ','; line << loads[i]; }
    line << "],\"system_cpu_busy_percent\":";
    if (hostOK && hasHost) {
      uint64_t total = 0, idle = 0;
      for (int i = 0; i < CPU_STATE_MAX; ++i) {
        uint32_t d = host.cpu_ticks[i] - previousHost.cpu_ticks[i]; total += d;
        if (i == CPU_STATE_IDLE) idle = d;
      }
      if (total) line << 100.0 * (total - idle) / total; else line << "null";
    } else line << "null";
    line << ",\"processes\":[" << rows.str() << "]}"; emit(line.str());
    if (hostOK) { previousHost = host; hasHost = true; }
    previousTicks = cycleEnd; summary.cpuNsObserved += cpuNs;
  }
  void run(double duration, double interval) {
    auto until = std::chrono::steady_clock::now() + std::chrono::duration<double>(duration);
    sample();
    while (std::chrono::steady_clock::now() < until) {
      std::this_thread::sleep_for(std::chrono::duration<double>(interval)); sample();
    }
    emit("{\"type\":\"summary\",\"samples\":" + std::to_string(summary.samples) +
         ",\"distinct_pids_observed\":" + std::to_string(summary.seen.size()) + ",\"reparentings\":" + std::to_string(summary.reparentings) +
         ",\"distinct_process_generations\":" + std::to_string(summary.generations.size()) +
         ",\"exits_observed\":" + std::to_string(summary.exits) + ",\"sampling_omissions\":" + std::to_string(summary.omissions) +
         ",\"enumeration_failures\":" + std::to_string(summary.enumerationsFailed) +
         ",\"cpu_ns_observed_lower_bound\":" + std::to_string(summary.cpuNsObserved) + "}");
  }
};

void sleepMS(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
int selfTest() {
  // Compare an independent POSIX process CPU clock against raw proc accounting
  // in an owned worker. Scheduler contention does not invalidate this ratio.
  int calibrationPipe[2]; if (pipe(calibrationPipe)) return 1;
  pid_t calibration = fork();
  if (calibration == 0) {
    close(calibrationPipe[0]);
    auto a = readProcess(getpid()); auto clockA = processCPUClock();
    const auto wallDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(6);
    double sum = 0;
    while (processCPUClock() - clockA < 200000000ULL && std::chrono::steady_clock::now() < wallDeadline) {
      for (int i = 1; i < 10000; ++i) sum += std::sqrt(static_cast<double>(i));
      asm volatile("" : "+m"(sum));
    }
    auto clockB = processCPUClock(); auto b = readProcess(getpid());
    uint64_t measured[2] = {0, clockB - clockA};
    if (a.value && b.value) measured[0] = nanoseconds(b.value->usage.ri_user_time - a.value->usage.ri_user_time) +
        nanoseconds(b.value->usage.ri_system_time - a.value->usage.ri_system_time);
    (void)write(calibrationPipe[1], measured, sizeof(measured)); _exit(0);
  }
  close(calibrationPipe[1]); uint64_t measured[2]{};
  auto readBytes = read(calibrationPipe[0], measured, sizeof(measured)); close(calibrationPipe[0]);
  if (calibration <= 0 || readBytes != sizeof(measured)) return 1;
  waitpid(calibration, nullptr, 0);
  double ratio = measured[1] ? static_cast<double>(measured[0]) / measured[1] : 0;
  int planPipe[2]; if (pipe(planPipe)) return 1;
  pid_t root = fork();
  if (root == 0) {
    close(planPipe[0]);
    pid_t middle = fork();
    if (middle == 0) {
      pid_t grandchild = fork();
      if (grandchild == 0) { close(planPipe[1]); sleepMS(2100); _exit(0); }
      pid_t plan[2] = {getpid(), grandchild}; (void)write(planPipe[1], plan, sizeof(plan));
      close(planPipe[1]); sleepMS(750); _exit(0);
    }
    close(planPipe[1]); sleepMS(2400); waitpid(middle, nullptr, 0); _exit(0);
  }
  close(planPipe[1]); pid_t plan[2]{};
  auto planBytes = read(planPipe[0], plan, sizeof(plan)); close(planPipe[0]);
  if (root <= 0 || planBytes != sizeof(plan) || plan[0] <= 0 || plan[1] <= 0) return 1;
  pid_t unrelated = fork();
  if (unrelated == 0) { sleepMS(2600); _exit(0); }
  if (unrelated < 0) return 1;
  Collector collector(root, [](const std::string&) {}); collector.run(2.8, 0.1);
  waitpid(root, nullptr, 0); waitpid(unrelated, nullptr, 0);
  bool exactTree = collector.summary.seen == std::set<pid_t>{root, plan[0], plan[1]};
  bool passed = ratio > 0.9 && ratio < 1.1 && measured[1] >= 150000000 && exactTree && collector.summary.reparentings >= 1 && collector.summary.exits >= 1;
  std::cout << "{\"self_test\":" << (passed ? "true" : "false")
            << ",\"timebase_numer\":" << timebase.numer << ",\"timebase_denom\":" << timebase.denom
            << ",\"worker_proc_cpu_ns\":" << measured[0] << ",\"worker_posix_cpu_ns\":" << measured[1]
            << ",\"cpu_clock_ratio\":" << ratio << ",\"exact_root_child_grandchild_set\":" << (exactTree ? "true" : "false")
            << ",\"unrelated_sibling_excluded\":" << (!collector.summary.seen.contains(unrelated) ? "true" : "false")
            << ",\"reparentings_observed\":" << collector.summary.reparentings << ",\"exits_observed\":" << collector.summary.exits
            << ",\"limit\":\"Synthetic correctness test only; not a browser performance result\"}\n";
  return passed ? 0 : 1;
}
}  // namespace

int main(int argc, char** argv) {
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) return 1;
  try {
    if (argc == 2 && std::string(argv[1]) == "--self-test") return selfTest();
    pid_t root = 0; double duration = 30, interval = 0.5; std::string path;
    for (int i = 1; i < argc; ++i) {
      std::string option = argv[i];
      if (option == "--help") {
        std::cout << "--root-pid PID [--duration SECONDS] [--interval SECONDS] [--output NEW_FILE.jsonl]\n--self-test\n"; return 0;
      }
      if (i + 1 == argc) throw std::runtime_error("Missing option value");
      std::string value = argv[++i]; size_t consumed = 0;
      if (option == "--root-pid") {
        long parsed = std::stol(value, &consumed); if (consumed != value.size() || parsed <= 1 || parsed > INT32_MAX) throw std::runtime_error("Invalid root PID");
        root = static_cast<pid_t>(parsed);
      } else if (option == "--duration" || option == "--interval") {
        double parsed = std::stod(value, &consumed); if (consumed != value.size() || !std::isfinite(parsed)) throw std::runtime_error("Invalid timing option");
        if (option == "--duration") duration = parsed; else interval = parsed;
      } else if (option == "--output") path = value;
      else throw std::runtime_error("Unknown option");
    }
    if (root <= 1 || duration <= 0 || duration > 3600 || interval < 0.05 || interval > 60)
      throw std::runtime_error("Require root PID; duration must be 0–3600 seconds and interval 0.05–60 seconds");
    FILE* output = stdout;
    if (!path.empty()) {
      int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
      if (fd < 0) throw std::runtime_error("Cannot create report (must be a new writable file)");
      output = fdopen(fd, "w"); if (!output) { close(fd); throw std::runtime_error("Cannot open report stream"); }
    }
    Collector collector(root, [output](const std::string& line) {
      if (fprintf(output, "%s\n", line.c_str()) < 0 || fflush(output)) throw std::runtime_error("Report write failed");
    });
    collector.run(duration, interval);
    if (output != stdout) fclose(output);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "Sampler: " << error.what() << '\n'; return 1;
  }
}
