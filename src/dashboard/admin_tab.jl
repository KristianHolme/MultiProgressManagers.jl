"""
Admin tab - for manually editing experiment records.
"""

function _view_admin_tab!(m::ProgressDashboard, area::Rect, buf)
    rows = split_layout(m.admin_layout, area)
    length(rows) < 2 && return
    
    # === Left: Experiment List ===
    list_block = Block(
        title = " All Experiments ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    list_area = render(list_block, rows[1], buf)
    
    if isempty(m.admin_experiments)
        set_string!(buf, list_area.x, list_area.y + 1, 
                   "No experiments found", tstyle(:text_dim); 
                   max_x = right(list_area))
    else
        # Build list items with status indicators
        items = map(m.admin_experiments) do exp
            status_char = @match exp.status begin
                :running => "●"
                :completed => "✓"
                :failed => "✗"
                _ => "○"
            end
            
            status_style = @match exp.status begin
                :running => :warning
                :completed => :success
                :failed => :error
                _ => :text_dim
            end
            
            "$status_char $(exp.name)"
        end
        
        list = SelectableList(items; selected = m.admin_selected)
        render(list, list_area, buf)
    end
    
    # === Right: Edit Panel ===
    edit_block = Block(
        title = " Edit Experiment ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    edit_area = render(edit_block, rows[2], buf)
    
    # Handle confirmation modal
    if m.admin_confirm_action !== nothing
        _render_confirm_modal!(m, edit_area, buf)
        return
    end
    
    # Handle edit mode
    if m.admin_edit_mode && m.admin_edit_input !== nothing
        _render_edit_mode!(m, edit_area, buf)
        return
    end
    
    # Normal view
    if m.admin_selected > 0 && m.admin_selected <= length(m.admin_experiments)
        _render_experiment_edit!(m, m.admin_experiments[m.admin_selected], edit_area, buf)
    else
        set_string!(buf, edit_area.x, edit_area.y + 1, 
                   "Select an experiment to edit", tstyle(:text_dim); 
                   max_x = right(edit_area))
    end
    
    # Hints
    hints = "[↑↓]select  [e]dit  [c]omplete  [r]eset  [d]elete  [q]uit"
    set_string!(buf, area.x, bottom(area), hints, tstyle(:text_dim); max_x = right(area))
end

function _render_experiment_edit!(m::ProgressDashboard, exp::ExperimentAdminView, area::Rect, buf)
    y = area.y
    x = area.x
    max_x = right(area)
    
    # Header
    set_string!(buf, x, y, exp.name, tstyle(:accent, bold = true); max_x = max_x)
    y += 1
    
    if !isempty(exp.description)
        set_string!(buf, x, y, exp.description, tstyle(:text_dim); max_x = max_x)
        y += 1
    end
    y += 1
    
    # Status with color
    status_style = @match exp.status begin
        :running => tstyle(:warning)
        :completed => tstyle(:success)
        :failed => tstyle(:error)
        _ => tstyle(:text)
    end
    
    set_string!(buf, x, y, "Status: ", tstyle(:text); max_x = max_x)
    set_string!(buf, x + 8, y, string(exp.status), status_style; max_x = max_x)
    y += 1
    
    # Progress
    progress_pct = exp.total_steps > 0 ? 100 * exp.current_step / exp.total_steps : 0
    set_string!(buf, x, y, "Progress: $(exp.current_step) / $(exp.total_steps) ($(sprintf("%.1f%%", progress_pct)))", 
               tstyle(:text); max_x = max_x)
    y += 1
    
    # Dates
    set_string!(buf, x, y, "Started: $(exp.started_at)", tstyle(:text_dim); max_x = max_x)
    y += 1
    
    if exp.finished_at !== nothing
        set_string!(buf, x, y, "Finished: $(exp.finished_at)", tstyle(:text_dim); max_x = max_x)
        y += 1
    end
    y += 1
    
    # Message
    if !isempty(exp.final_message)
        set_string!(buf, x, y, "Message:", tstyle(:accent); max_x = max_x)
        y += 1
        # Word wrap message
        msg_lines = _word_wrap(exp.final_message, area.width - 2)
        for line in msg_lines[1:min(3, length(msg_lines))]
            if y > bottom(area) - 2
                break
            end
            set_string!(buf, x, y, line, tstyle(:text); max_x = max_x)
            y += 1
        end
        if length(msg_lines) > 3
            set_string!(buf, x, y, "...", tstyle(:text_dim); max_x = max_x)
        end
    end
    
    y = bottom(area) - 2
    set_string!(buf, x, y, "Press [e] to edit fields", tstyle(:accent); max_x = max_x)
end

function _render_edit_mode!(m::ProgressDashboard, area::Rect, buf)
    y = area.y
    x = area.x
    max_x = right(area)
    
    exp = m.admin_experiments[m.admin_selected]
    
    set_string!(buf, x, y, "Edit Mode - Field $(m.admin_edit_field)/3", tstyle(:accent, bold = true); max_x = max_x)
    y += 2
    
    field_names = ["Status (running/completed/failed/cancelled)", "Current Step (integer)", "Message (text)"]
    
    set_string!(buf, x, y, "Editing: $(field_names[m.admin_edit_field])", tstyle(:text); max_x = max_x)
    y += 2
    
    # Render the TextInput
    if m.admin_edit_input !== nothing
        set_string!(buf, x, y, "Value: ", tstyle(:text); max_x = max_x)
        input_area = Rect(x + 7, y, area.width - 8, 1)
        render(m.admin_edit_input, input_area, buf)
    end
    
    y = bottom(area) - 2
    set_string!(buf, x, y, "[Enter]save  [Tab]next field  [Esc]cancel", tstyle(:text_dim); max_x = max_x)
end

function _render_confirm_modal!(m::ProgressDashboard, area::Rect, buf)
    # Dim background
    for row in area.y:bottom(area)
        for col in area.x:right(area)
            set_char!(buf, col, row, ' ', Style(fg = Color256(238)))
        end
    end
    
    # Modal box
    modal_w = 40
    modal_h = 5
    modal_rect = center(area, modal_w, modal_h)
    
    block = Block(
        title = " Confirm ",
        border_style = tstyle(:warning, bold = true),
        title_style = tstyle(:warning, bold = true),
        box = BOX_HEAVY
    )
    content = render(block, modal_rect, buf)
    
    # Message
    action_str = @match m.admin_confirm_action begin
        :complete => "mark this experiment as completed"
        :reset => "reset this experiment to running"
        :delete => "DELETE this experiment"
        _ => "perform this action"
    end
    
    y = content.y
    set_string!(buf, content.x, y, "Are you sure you want to", tstyle(:text); max_x = right(content))
    y += 1
    set_string!(buf, content.x, y, action_str * "?", tstyle(:warning); max_x = right(content))
    y += 2
    set_string!(buf, content.x, y, "[y]es  [n]o", tstyle(:accent); max_x = right(content))
end

function _word_wrap(text::String, width::Int)::Vector{String}
    words = split(text)
    lines = String[]
    current_line = ""
    
    for word in words
        if length(current_line) + length(word) + 1 <= width
            if isempty(current_line)
                current_line = word
            else
                current_line *= " " * word
            end
        else
            push!(lines, current_line)
            current_line = word
        end
    end
    
    if !isempty(current_line)
        push!(lines, current_line)
    end
    
    return lines
end

# Helper to match status to style
@match = Match
