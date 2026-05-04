# frozen_string_literal: true

# Verifies that the CORE_AUTOSTART-gated block has been fully removed from
# dependency.lic. These are source-file-content specs -- they read the file
# and assert patterns exist or do not exist, without loading the script
# (which requires heavy game infrastructure).
#
# The removed block contained:
# - A one-way merge of Settings['autostart'] into UserVars.autostart_scripts
#   (the root cause of the "purge but scripts come back" bug)
# - handle_obsolete_autostart() -- now handled by autostart.lic
# - dr_obsolete_script?() -- also defined in CORE_DR_STARTUP gate
# - autostart() -- no longer needed, managed via YAML autostarts setting
# - stop_autostart() -- no longer needed
# - dependency_status() -- no longer needed

DEP_PATH = File.expand_path(File.join(__dir__, '..', 'dependency.lic'))
DEP_CONTENT = File.read(DEP_PATH)

RSpec.describe 'CORE_AUTOSTART block removal from dependency.lic' do
  describe 'removed gate' do
    it 'does not contain the CORE_AUTOSTART sentinel check' do
      expect(DEP_CONTENT).not_to include('const_defined?(:CORE_AUTOSTART')
    end

    it 'does not contain the autostart helpers gate comment' do
      expect(DEP_CONTENT).not_to include('Autostart helpers gate')
    end
  end

  describe 'removed zombie merge code' do
    it 'does not contain the perpetual merge into UserVars.autostart_scripts' do
      expect(DEP_CONTENT).not_to include('UserVars.autostart_scripts = merged')
    end

    it 'does not contain the zombie merge echo message' do
      expect(DEP_CONTENT).not_to include('Merging global autostarts into character autostarts')
    end
  end

  describe 'one-shot orphan cleanup' do
    it "clears Settings['autostart'] if present" do
      expect(DEP_CONTENT).to include("Settings['autostart'] = nil")
    end

    it 'saves after clearing' do
      cleanup_block = DEP_CONTENT[/if Settings\['autostart'\].*?end/m]
      expect(cleanup_block).not_to be_nil
      expect(cleanup_block).to include('Settings.save')
    end

    it 'only runs once (conditional on Settings having the key)' do
      expect(DEP_CONTENT).to match(/^if Settings\['autostart'\]/)
    end
  end

  describe 'removed autostart helper functions' do
    it 'does not define handle_obsolete_autostart()' do
      expect(DEP_CONTENT).not_to match(/^\s*def handle_obsolete_autostart\b/)
    end

    it 'does not define autostart() as a top-level function' do
      # ScriptManager#autostarts is a different method and should remain.
      # We check for a top-level def autostart( with arguments.
      expect(DEP_CONTENT).not_to match(/^\s*def autostart\(/)
    end

    it 'does not define stop_autostart()' do
      expect(DEP_CONTENT).not_to match(/^\s*def stop_autostart\b/)
    end

    it 'does not define dependency_status()' do
      expect(DEP_CONTENT).not_to match(/^\s*def dependency_status\b/)
    end
  end

  describe 'preserved gates -- ensures we did not remove too much' do
    it 'still contains the CORE_GET_SETTINGS gate' do
      expect(DEP_CONTENT).to include('const_defined?(:CORE_GET_SETTINGS')
    end

    it 'still contains the ScriptManager class inside CORE_GET_SETTINGS' do
      expect(DEP_CONTENT).to include('class ScriptManager')
    end

    it 'still contains the CORE_DR_STARTUP gate' do
      expect(DEP_CONTENT).to include('const_defined?(:CORE_DR_STARTUP')
    end

    it 'still contains DR_OBSOLETE_SCRIPTS inside CORE_DR_STARTUP' do
      expect(DEP_CONTENT).to include('DR_OBSOLETE_SCRIPTS')
    end

    it 'still contains the CORE_SCRIPT_LOADER gate' do
      expect(DEP_CONTENT).to include('const_defined?(:CORE_SCRIPT_LOADER')
    end

    it 'still contains the CORE_MAP_OVERRIDES gate' do
      expect(DEP_CONTENT).to include('const_defined?(:CORE_MAP_OVERRIDES')
    end

    it 'still defines warn_obsolete_scripts in CORE_DR_STARTUP' do
      expect(DEP_CONTENT).to match(/def warn_obsolete_scripts/)
    end

    it 'still defines warn_obsolete_data_files in CORE_DR_STARTUP' do
      expect(DEP_CONTENT).to match(/def warn_obsolete_data_files/)
    end
  end

  describe 'structural integrity' do
    it 'ScriptManager gate closing comment is present' do
      expect(DEP_CONTENT).to include('end # ScriptManager gate')
    end

    it 'CORE_DR_STARTUP gate closing comment is present' do
      expect(DEP_CONTENT).to include('end # CORE_DR_STARTUP gate')
    end

    it 'no function defs or gate blocks between ScriptManager and CORE_DR_STARTUP' do
      manager_end = DEP_CONTENT.index('end # ScriptManager gate')
      startup_gate = DEP_CONTENT.index('# --- CORE_DR_STARTUP gate ---')
      expect(manager_end).not_to be_nil
      expect(startup_gate).not_to be_nil
      between = DEP_CONTENT[manager_end..startup_gate]
      expect(between).not_to include('def ')
      expect(between).not_to include('unless ')
    end
  end
end
