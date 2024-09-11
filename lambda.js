function escapeHtml(unsafe) {
    return unsafe
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}

// Main function to handle requests
function main(request) {
    const { method, query, body } = request;

    // Router
    if (method === 'GET') {
        return listTodos();
    } else if (method === 'POST' && body) {
        if (body.action === 'add') {
            return addTodo(body.text);
        } else if (body.action === 'delete') {
            return deleteTodo(body.id);
        }
    }

    return { status: 400, body: 'Bad Request' };
}

// List all todos
function listTodos() {
    const todos = plv8.execute('SELECT id, text FROM todos ORDER BY id');
    
    let html = `
        <h1>Todo List</h1>
        <ul>
    `;
    
    todos.forEach(todo => {
        html += `
            <li>
                ${escapeHtml(todo.text)}
                <form method="POST" style="display: inline;">
                    <input type="hidden" name="action" value="delete">
                    <input type="hidden" name="id" value="${todo.id}">
                    <button type="submit">Delete</button>
                </form>
            </li>
        `;
    });
    
    html += `
        </ul>
        <h2>Add New Todo</h2>
        <form method="POST">
            <input type="hidden" name="action" value="add">
            <input type="text" name="text" required>
            <button type="submit">Add Todo</button>
        </form>
    `;

    return { status: 200, body: html, headers: { 'Content-Type': 'text/html' } };
}

// Add a new todo
function addTodo(text) {
    plv8.execute('INSERT INTO todos(text) VALUES($1)', [text]);
    return { status: 302, headers: { 'Location': './' } };
}

// Delete a todo
function deleteTodo(id) {
    plv8.execute('DELETE FROM todos WHERE id = $1', [id]);
    return { status: 302, headers: { 'Location': './' } };
}

return main(req)