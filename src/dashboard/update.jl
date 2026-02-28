"""
Event handling for the dashboard.
"""

function Tachikoma.update!(m::ProgressDashboard, evt::KeyEvent)
    # Global keys
    if evt.key == :q || evt.key == :Q
        m.quit = true
        return
    end
    
    # Tab switching
    max_tab = m.folder_mode ? 4 : 3
    
    if evt.key == :f1 || (evt.key == :char && evt.char == '1')
        m.active_tab = 1
    elseif evt.key == :f2 || (evt.key == :char && evt.char == '2')
        m.active_tab = min(2, max_tab)
    elseif evt.key == :f3 || (evt.key == :char && evt.char == '3')
        m.active_tab = min(3, max_tab)
    elseif (evt.key == :f4 || (evt.key == :char && evt.char == '4')) && max_tab >= 4
        m.active_tab = 4
    elseif evt.key == :left || (evt.key == :char && evt.char == 'h')
        m.active_tab = max(1, m.active_tab - 1)
    elseif evt.key == :right || (evt.key == :char && evt.char == 'l')
        m.active_tab = min(max_tab, m.active_tab + 1)
    end
    
    # Route to tab-specific handler
    @match m.active_tab begin
        1 => _update_select_tab!(m, evt)
        2 => _update_running_tab!(m, evt)
        3 => _update_stats_tab!(m, evt)
        4 => _update_admin_tab!(m, evt)
        _ => nothing
    end
end

# === Select Tab (Folder Mode) ===

function _update_select_tab!(m::ProgressDashboard, evt::KeyEvent)
    if evt.key == :up || evt.key == :ctrl && evt.char == 'k'
        m.selected_db_index = max(0, m.selected_db_index - 1)
    elseif evt.key == :down || evt.key == :ctrl && evt.char == 'j'
        m.selected_db_index = min(length(m.available_dbs), m.selected_db_index + 1)
    elseif evt.key == :enter && m.selected_db_index > 0
        # Switch to selected database
        new_db = m.available_dbs[m.selected_db_index]
        m.db_path = new_db
        Database.close_db!(m.db_handle)
        m.db_handle = Database.init_db!(new_db)
        # Switch to running tab
        m.active_tab = 2
    end
end

# === Running Tab ===

function _update_running_tab!(m::ProgressDashboard, evt::KeyEvent)
    isempty(m.running_experiments) && return
    
    if evt.key == :up || evt.key == :ctrl && evt.char == 'k'
        m.selected_experiment = max(1, m.selected_experiment - 1)
    elseif evt.key == :down || evt.key == :ctrl && evt.char == 'j'
        m.selected_experiment = min(length(m.running_experiments), m.selected_experiment + 1)
    elseif m.selected_experiment == 0 && !isempty(m.running_experiments)
        m.selected_experiment = 1
    end
end

# === Stats Tab ===

function _update_stats_tab!(m::ProgressDashboard, evt::KeyEvent)
    # Stats are read-only, no interaction needed
    # Could add: [r]efresh, time range selection
    if evt.key == :char && evt.char == 'r'
        # Force refresh
        m.last_stats_refresh = 0.0
    end
end

# === Admin Tab ===

function _update_admin_tab!(m::ProgressDashboard, evt::KeyEvent)
    # Handle confirmation modal
    if m.admin_confirm_action !== nothing
        _handle_confirm_modal!(m, evt)
        return
    end
    
    # Handle edit mode
    if m.admin_edit_mode
        _handle_edit_mode!(m, evt)
        return
    end
    
    # Normal mode - navigation and actions
    isempty(m.admin_experiments) && return
    
    if evt.key == :up || evt.key == :ctrl && evt.char == 'k'
        m.admin_selected = max(1, m.admin_selected - 1)
    elseif evt.key == :down || evt.key == :ctrl && evt.char == 'j'
        m.admin_selected = min(length(m.admin_experiments), m.admin_selected + 1)
    elseif m.admin_selected == 0 && !isempty(m.admin_experiments)
        m.admin_selected = 1
    elseif evt.key == :char && evt.char == 'e'
        # Edit selected experiment
        _enter_edit_mode!(m)
    elseif evt.key == :char && evt.char == 'c'
        # Mark as completed
        m.admin_confirm_action = :complete
    elseif evt.key == :char && evt.char == 'r'
        # Reset to running
        m.admin_confirm_action = :reset
    elseif evt.key == :char && evt.char == 'd'
        # Delete
        m.admin_confirm_action = :delete
    end
end

function _enter_edit_mode!(m::ProgressDashboard)
    m.admin_selected == 0 && return
    
    exp = m.admin_experiments[m.admin_selected]
    
    # Initialize edit input based on selected field
    initial_text = @match m.admin_edit_field begin
        1 => string(exp.status)
        2 => string(exp.current_step)
        3 => exp.final_message
        _ => ""
    end
    
    m.admin_edit_input = TextInput(initial_text)
    m.admin_edit_mode = true
end

function _handle_edit_mode!(m::ProgressDashboard, evt::KeyEvent)
    input = m.admin_edit_input
    input === nothing && return
    
    # Pass to text input
    Tachikoma.handle_key!(input, evt)
    
    if evt.key == :enter
        # Save changes
        _save_admin_edit!(m)
        m.admin_edit_mode = false
        m.admin_edit_input = nothing
    elseif evt.key == :escape
        # Cancel
        m.admin_edit_mode = false
        m.admin_edit_input = nothing
    elseif evt.key == :tab
        # Cycle through fields
        m.admin_edit_field = mod1(m.admin_edit_field + 1, 3)
        _enter_edit_mode!(m)  # Re-initialize with new field
    end
end

function _save_admin_edit!(m::ProgressDashboard)
    m.admin_selected == 0 && return
    
    exp = m.admin_experiments[m.admin_selected]
    input = m.admin_edit_input
    input === nothing && return
    
    value = Tachikoma.text(input)
    
    @match m.admin_edit_field begin
        1 => Database.update_experiment_status!(m.db_handle, exp.id, value)
        2 => begin
            new_step = parse(Int, value)
            Database.update_experiment_steps!(m.db_handle, exp.id, new_step)
        end
        3 => Database.update_experiment_status!(m.db_handle, exp.id, string(exp.status); message=value)
        _ => nothing
    end
end

function _handle_confirm_modal!(m::ProgressDashboard, evt::KeyEvent)
    if evt.key == :char && evt.char == 'y'
        # Confirm action
        exp = m.admin_experiments[m.admin_selected]
        
        @match m.admin_confirm_action begin
            :complete => Database.update_experiment_status!(m.db_handle, exp.id, "completed")
            :reset => Database.update_experiment_status!(m.db_handle, exp.id, "running")
            :delete => _delete_experiment!(m, exp.id)
            _ => nothing
        end
        
        m.admin_confirm_action = nothing
    elseif evt.key == :char && evt.char == 'n' || evt.key == :escape
        # Cancel
        m.admin_confirm_action = nothing
    end
end

function _delete_experiment!(m::ProgressDashboard, experiment_id::String)
    # Actually delete from database
    db = Database.ensure_open!(m.db_handle)
    DBInterface.execute(db, "DELETE FROM experiments WHERE id = ?", [experiment_id])
end
