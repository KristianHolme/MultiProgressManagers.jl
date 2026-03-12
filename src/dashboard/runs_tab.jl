"""
Runs list tab - shows all experiments from the database.
"""

function _view_runs_tab!(m::ProgressDashboard, area::Rect, buf::Buffer)
    # Render outer block
    outer = Block(
        title = " All Experiments ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    inner = render(outer, area, buf)
    
    # Use admin_experiments from model (refreshed by _poll_database!)
    experiments = m.admin_experiments
    
    if isempty(experiments)
        set_string!(buf, inner.x, inner.y + 1, "No experiments found", tstyle(:text_dim); max_x = right(inner))
        return
    end
    
    # Header for the list
    header_y = inner.y
    header_style = tstyle(:text_dim, bold = true)
    
    # Column positions
    col_time = inner.x
    col_name = inner.x + 10
    col_status = inner.x + 35
    col_progress = inner.x + 48
    col_duration = inner.x + 65
    
    set_string!(buf, col_time, header_y, "Started", header_style)
    set_string!(buf, col_name, header_y, "Name", header_style)
    set_string!(buf, col_status, header_y, "Status", header_style)
    set_string!(buf, col_progress, header_y, "Completed", header_style)
    set_string!(buf, col_duration, header_y, "Duration", header_style)
    
    # Prepare items for SelectableList
    items = map(experiments) do exp
        name = ismissing(exp.name) ? "Unknown" : exp.name
        status = ismissing(exp.status) ? "unknown" : string(exp.status)
        
        # Calculate experiment-level progress: completed tasks / total tasks
        total_tasks = ismissing(exp.total_tasks) ? 0 : exp.total_tasks
        completed_tasks = ismissing(exp.completed_tasks) ? 0 : exp.completed_tasks
        
        progress_pct = total_tasks > 0 ? (completed_tasks / total_tasks) * 100 : 0.0
        
        # Calculate duration
        started_at = exp.started_at
        finished_at = ismissing(exp.finished_at) ? nothing : exp.finished_at
        duration_str = format_duration(started_at, finished_at)
        
        # Format label with columns
        start_time_str = format_datetime(started_at)
        progress_str = @sprintf("%d/%d (%.0f%%)", completed_tasks, total_tasks, progress_pct)
        label = @sprintf("%-10s %-24s %-12s %-18s %-15s",
                        start_time_str,
                        length(name) > 23 ? name[1:20] * "..." : name,
                        status,
                        progress_str,
                        duration_str)
        
        # Style based on status
        style = @match Symbol(status) begin
            :running => tstyle(:warning)
            :completed => tstyle(:success)
            :failed => tstyle(:error)
            _ => tstyle(:text)
        end
        
        ListItem(label, style)
    end
    
    # Render SelectableList
    list = SelectableList(items; selected = m.runs_selected)
    list_area = Rect(inner.x, inner.y + 1, inner.width, inner.height - 1)
    render(list, list_area, buf)
end

function _view_task_histogram!(m::ProgressDashboard, area::Rect, buf::Buffer)
    # 1. Get selected experiment ID
    exp_id = m.selected_experiment_id
    if isempty(exp_id) && m.runs_selected > 0 && m.runs_selected <= length(m.admin_experiments)
        exp = m.admin_experiments[m.runs_selected]
        exp_id = ismissing(exp.id) ? "" : exp.id
    end
    
    if isempty(exp_id)
        return
    end

    handle = _handle_for_experiment(m, exp_id)
    if handle === nothing
        return
    end

    # 2. Query tasks
    tasks = Database.get_experiment_tasks(handle, exp_id)
    if isempty(tasks)
        return
    end
    
    # 3. Calculate bins (11 bins: 0-10%, 10-20%, ..., 90-100%, 100%)
    bins = zeros(Int, 11)
    for row in eachrow(tasks)
        total = ismissing(row.total_steps) ? 0 : row.total_steps
        current = ismissing(row.current_step) ? 0 : row.current_step
        pct = total > 0 ? current / total : 0.0
        bin_idx = pct >= 1.0 ? 11 : (floor(Int, pct * 10) + 1)
        bins[bin_idx] += 1
    end

    # 4. Render BarChart
    labels = ["[0,10)%", "[10,20)%", "[20,30)%", "[30,40)%", "[40,50)%", "[50,60)%", "[60,70)%", "[70,80)%", "[80,90)%", "[90,100)%", "100%"]
    entries = [BarEntry(labels[i], bins[i]) for i in 1:11]
    max_count = maximum(bins)
    
    chart = BarChart(entries; max_val = (max_count > 0 ? max_count : 1))
    
    block = Block(title = " Task Completion Distribution ", border_style = tstyle(:border))
    inner_area = render(block, area, buf)
    render(chart, inner_area, buf)
end
