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

    # If oldest experiment was not started today, show date in Started column
    today_utc = Dates.Date(Dates.now(Dates.UTC))
    started_dates = [Dates.Date(exp.started_at) for exp in experiments if !ismissing(exp.started_at)]
    show_date = !isempty(started_dates) && minimum(started_dates) < today_utc
    time_col_width = show_date ? 16 : 10

    # Column positions
    col_time = inner.x
    col_name = inner.x + time_col_width
    col_status = inner.x + time_col_width + 25
    col_progress = inner.x + time_col_width + 38
    col_duration = inner.x + time_col_width + 55

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
        start_time_str = format_datetime_for_started_column(started_at, show_date)
        progress_str = @sprintf("%d/%d (%.0f%%)", completed_tasks, total_tasks, progress_pct)
        label = if show_date
            @sprintf("%-16s %-24s %-12s %-18s %-15s",
                    start_time_str,
                    length(name) > 23 ? name[1:20] * "..." : name,
                    status,
                    progress_str,
                    duration_str)
        else
            @sprintf("%-10s %-24s %-12s %-18s %-15s",
                    start_time_str,
                    length(name) > 23 ? name[1:20] * "..." : name,
                    status,
                    progress_str,
                    duration_str)
        end
        
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

    # 2. Query tasks and compute bins (11 bins: 0-10%, 10-20%, ..., 90-100%, 100%)
    tasks = Database.get_experiment_tasks(handle, exp_id)
    bins = zeros(Int, 11)
    if !isempty(tasks)
        for row in eachrow(tasks)
            total = ismissing(row.total_steps) ? 0 : row.total_steps
            current = ismissing(row.current_step) ? 0 : row.current_step
            pct = total > 0 ? current / total : 0.0
            bin_idx = pct >= 1.0 ? 11 : (floor(Int, pct * 10) + 1)
            bins[bin_idx] += 1
        end
    end
    # If no counts in any bin (no task rows, or all rows had total_steps=0), use experiment row for synthetic "all at 100%"
    if maximum(bins) == 0
        exp_row = Database.get_experiment(handle, exp_id)
        if exp_row === nothing
            return
        end
        status = ismissing(exp_row.status) ? "" : String(exp_row.status)
        total_tasks = ismissing(exp_row.total_tasks) ? 0 : Int(exp_row.total_tasks)
        if (status == "completed" || status == "failed") && total_tasks > 0
            bins[11] = total_tasks
        else
            return
        end
    end

    # 3. Render BarChart
    labels = ["[0,10)%", "[10,20)%", "[20,30)%", "[30,40)%", "[40,50)%", "[50,60)%", "[60,70)%", "[70,80)%", "[80,90)%", "[90,100)%", "100%"]
    entries = [BarEntry(labels[i], bins[i]) for i in 1:11]
    max_count = maximum(bins)
    chart = BarChart(entries; max_val = (max_count > 0 ? max_count : 1))
    block = Block(title = " Task Completion Distribution ", border_style = tstyle(:border))
    inner_area = render(block, area, buf)
    render(chart, inner_area, buf)
    return
end
