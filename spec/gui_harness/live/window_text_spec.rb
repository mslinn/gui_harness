# frozen_string_literal: false

require 'spec_helper'
require 'open3'
require 'tempfile'

# The examples ask the PowerShell script to read the text of a window from its pixels.
#
# Live draws its own windows, and nothing in the window tree describes them, so the pixels
# are the only place their text is. The window here is an ordinary one, and it is the
# capture and the OCR that are being proved.
RSpec.describe 'the text of a window, read from its pixels' do
  # The path of the PowerShell script of the Live layer.
  #
  # @return [String] the path
  def script_path
    File.expand_path '../../../assets/live/run.ps1', __dir__
  end

  # Runs an expression against the PowerShell script of the Live layer.
  #
  # @param expression [String] the PowerShell expression to run
  # @return [String] the output of the expression
  def powershell(expression)
    script = GuiHarness::Live::Launcher.windows_path script_path
    command = ". '#{script}' -Exe notepad.exe -Set C:/missing.txt; #{expression}"
    output, = Open3.capture2e 'powershell.exe', '-NoProfile', '-Command', command
    output
  end

  # Starts a process that puts up a window with a known text in it.
  #
  # The window is big, and the text in it is big, because the OCR has few pixels to work
  # with on a small window.
  #
  # @return [Array] the pid of the process and the pid of the process that was started
  def start_window
    pid_file = Tempfile.new(['gui_harness_window_text', '.pid'])
    pid_file.close
    path = GuiHarness::Live::Launcher.windows_path pid_file.path

    body = 'Add-Type -AssemblyName System.Windows.Forms; ' \
           'Add-Type -AssemblyName System.Drawing; ' \
           '$form = New-Object System.Windows.Forms.Form; ' \
           "$form.Text = 'GUI HARNESS OCR WINDOW'; " \
           '$form.Width = 900; $form.Height = 300; ' \
           '$label = New-Object System.Windows.Forms.Label; ' \
           "$label.Text = 'GUI HARNESS OCR'; " \
           "$label.Font = New-Object System.Drawing.Font('Arial', 36); " \
           '$label.AutoSize = $true; ' \
           '$form.Controls.Add($label); ' \
           "Set-Content -Path '#{path}' -Value $PID; " \
           '$null = $form.ShowDialog()'

    log = Tempfile.new(['gui_harness_window_text', '.log'])
    log.close
    spawn_pid = Process.spawn 'powershell.exe', '-NoProfile', '-Command', body, out: log.path, err: log.path
    pid = wait_for_pid pid_file.path
    wait_for_window pid
    [pid, spawn_pid]
  end

  # Waits for the process to write its pid down.
  #
  # @param path [String] the path of the file the pid is in
  # @return [Integer] the pid
  def wait_for_pid(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      break if File.exist?(path) && !File.read(path).strip.empty?
      raise 'the window did not come up' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
    File.read(path).strip.to_i
  end

  # Waits for the process to have a window of its own.
  #
  # @param pid [Integer] the pid of the process
  def wait_for_window(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      return if powershell("@(Get-Windows #{pid}).Count").strip.to_i.positive?
      raise 'the window did not come up' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.2
    end
  end

  # Stops a window that was put up.
  #
  # @param spawn_pid [Integer] the pid of the process that was started
  def stop_window(spawn_pid)
    Process.kill 'KILL', spawn_pid
    Process.wait spawn_pid
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  it 'reads the text of the window' do
    pid, spawn_pid = start_window

    expression = "$window = @(Get-Windows #{pid})[0]; " \
                 "'text=' + (Get-WindowText $window.Handle)"
    text = powershell(expression).strip

    expect(text).to match(/HARNESS/i), "the OCR read: #{text}"
  ensure
    stop_window spawn_pid
  end
end
