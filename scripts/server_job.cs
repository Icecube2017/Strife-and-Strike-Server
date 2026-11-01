// Windows process ownership for server.ps1. No WMI, PID files or image-name kills.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace SnsServerControl
{
    public sealed class ServerJob : IDisposable
    {
        private IntPtr job;
        private IntPtr process;
        public int ProcessId { get; private set; }

        public ServerJob(string name)
        {
            job = CreateJobObject(IntPtr.Zero, name);
            if (job == IntPtr.Zero) throw Error("CreateJobObject");
            var limits = new ExtendedLimits();
            limits.Basic.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(limits)))
            {
                var error = Error("SetInformationJobObject");
                Dispose();
                throw error;
            }
        }

        public void Start(string executable, string[] arguments, string directory, string logPath)
        {
            if (process != IntPtr.Zero) throw new InvalidOperationException("Job already started.");
            SafeFileHandle input, inputWriter;
            if (!CreatePipe(out input, out inputWriter, IntPtr.Zero, 0)) throw Error("CreatePipe");
            using (input)
            using (inputWriter)
            using (var log = new FileStream(logPath, FileMode.CreateNew, FileAccess.Write,
                                           FileShare.ReadWrite | FileShare.Delete))
            {
                // NUL is FILE_TYPE_CHAR: Dart considers it a terminal then fails SetConsoleMode.
                // A closed pipe correctly reports redirected input to dart_frog's helpers.
                if (!SetHandleInformation(log.SafeFileHandle, 1, 1) ||
                    !SetHandleInformation(input, 1, 1)) throw Error("SetHandleInformation");
                var info = new StartupInfo();
                info.Size = Marshal.SizeOf(info);
                info.Flags = 0x101; // STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
                info.ShowWindow = 0; // Separate, hidden console: Ctrl+C cannot reach other apps.
                info.Input = input.DangerousGetHandle();
                info.Output = info.Error = log.SafeFileHandle.DangerousGetHandle();
                var command = new StringBuilder(Quote(executable));
                foreach (var argument in arguments) command.Append(" ").Append(Quote(argument));
                ProcessInfo child;
                if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true,
                                   0x14, IntPtr.Zero, directory, ref info, out child))
                    throw Error("CreateProcess"); // CREATE_SUSPENDED | CREATE_NEW_CONSOLE
                process = child.Process;
                ProcessId = (int)child.ProcessId;
                try
                {
                    // Assign BEFORE resuming: even very short-lived parents cannot escape the job.
                    if (!AssignProcessToJobObject(job, process)) throw Error("AssignProcessToJobObject");
                    if (ResumeThread(child.Thread) == UInt32.MaxValue) throw Error("ResumeThread");
                }
                catch
                {
                    TerminateProcess(process, 1);
                    throw;
                }
                finally { CloseHandle(child.Thread); }
            }
        }

        public bool HasExited
        {
            get { return process != IntPtr.Zero && WaitForSingleObject(process, 0) == 0; }
        }

        public uint ExitCode
        {
            get
            {
                uint code;
                if (!GetExitCodeProcess(process, out code)) throw Error("GetExitCodeProcess");
                return code;
            }
        }

        public int[] ProcessIds()
        {
            for (int size = 4096; size <= 1024 * 1024; size *= 2)
            {
                var buffer = Marshal.AllocHGlobal(size);
                try
                {
                    int returned;
                    if (!QueryInformationJobObject(job, 3, buffer, size, out returned))
                    {
                        if (Marshal.GetLastWin32Error() == 234) continue; // ERROR_MORE_DATA
                        throw Error("QueryInformationJobObject");
                    }
                    var count = Marshal.ReadInt32(buffer, 4);
                    var ids = new int[count];
                    for (var index = 0; index < count; index++)
                        ids[index] = (int)Marshal.ReadIntPtr(buffer, 8 + index * IntPtr.Size).ToInt64();
                    return ids;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("Job process list is too large.");
        }

        public void Terminate()
        {
            if (job != IntPtr.Zero && !TerminateJobObject(job, 1)) throw Error("TerminateJobObject");
        }

        public static bool TerminateOwnedJob(string name)
        {
            var handle = OpenJobObject(8, false, name); // JOB_OBJECT_TERMINATE
            if (handle == IntPtr.Zero)
            {
                if (Marshal.GetLastWin32Error() == 2) return false;
                throw Error("OpenJobObject");
            }
            try
            {
                if (!TerminateJobObject(handle, 1)) throw Error("TerminateJobObject");
                return true;
            }
            finally { CloseHandle(handle); }
        }

        // Called ONLY in a disposable helper process, never in the supervisor's console.
        public static bool InterruptConsole(int processId)
        {
            FreeConsole();
            if (!AttachConsole((uint)processId)) return false;
            try
            {
                if (!SetConsoleCtrlHandler(IntPtr.Zero, true)) throw Error("SetConsoleCtrlHandler");
                if (!GenerateConsoleCtrlEvent(0, 0)) throw Error("GenerateConsoleCtrlEvent");
                Thread.Sleep(250);
                return true;
            }
            finally { FreeConsole(); }
        }

        public static int[] ListeningProcessIds(int port)
        {
            var ids = new HashSet<int>();
            AddListeningProcessIds(port, 2, 24, 8, 20, ids); // MIB_TCPROW_OWNER_PID (IPv4)
            AddListeningProcessIds(port, 23, 56, 20, 52, ids); // MIB_TCP6ROW_OWNER_PID (IPv6)
            var array = new int[ids.Count];
            ids.CopyTo(array);
            return array;
        }

        private static void AddListeningProcessIds(int port, int family, int rowSize,
                                                   int portOffset, int pidOffset, HashSet<int> ids)
        {
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 3, 0);
            while (true)
            {
                var buffer = Marshal.AllocHGlobal(size);
                try
                {
                    var result = GetExtendedTcpTable(buffer, ref size, false, family, 3, 0);
                    if (result == 122) continue; // ERROR_INSUFFICIENT_BUFFER
                    if (result != 0) throw new Win32Exception((int)result, "GetExtendedTcpTable: " + new Win32Exception((int)result).Message);
                    var count = Marshal.ReadInt32(buffer);
                    for (var index = 0; index < count; index++)
                    {
                        var offset = 4 + index * rowSize;
                        var networkPort = Marshal.ReadInt32(buffer, offset + portOffset);
                        var localPort = ((networkPort & 255) << 8) | ((networkPort >> 8) & 255);
                        if (localPort == port) ids.Add(Marshal.ReadInt32(buffer, offset + pidOffset));
                    }
                    return;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }

        public void Dispose()
        {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
            GC.SuppressFinalize(this);
        }

        ~ServerJob() { Dispose(); }

        private static Win32Exception Error(string operation)
        {
            var code = Marshal.GetLastWin32Error();
            return new Win32Exception(code, operation + ": " + new Win32Exception(code).Message);
        }

        // CommandLineToArgvW-compatible quoting, including trailing slashes and quotes.
        private static string Quote(string value)
        {
            var result = new StringBuilder("\"");
            var slashes = 0;
            foreach (var character in value)
            {
                if (character == '\\') { slashes++; continue; }
                result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
                result.Append(character);
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
        {
            public long ProcessTime, JobTime;
            public uint LimitFlags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters
        {
            public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XChars, YChars, Fill;
            public int Flags;
            public short ShowWindow, ReservedSize;
            public IntPtr ReservedData, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo
        {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, int length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int length, out int returned);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
            ref StartupInfo startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, uint size);
        [DllImport("kernel32.dll")] private static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint signal, uint group);
        [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int tableClass, uint reserved);
    }
}
