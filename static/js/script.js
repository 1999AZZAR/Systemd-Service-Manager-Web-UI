document.addEventListener('DOMContentLoaded', function() {
    // --- Cache DOM elements ---
    const rootHtml = document.documentElement;
    const serviceListBody = document.getElementById('service-list');
    const loader = document.getElementById('loader');
    const serviceTableContainer = document.getElementById('service-table-container');
    const serviceTableHead = document.getElementById('service-table-head');
    const searchInput = document.getElementById('search-input');
    const noResults = document.getElementById('no-results');
    const refreshButton = document.getElementById('refresh-button');
    const daemonReloadButton = document.getElementById('daemon-reload-button');

    // Status Modal Elements
    const statusModal = document.getElementById('status-modal');
    const statusModalTitle = document.getElementById('status-modal-title');
    const statusModalContent = document.getElementById('status-modal-content');

    // File Modal Elements
    const fileModal = document.getElementById('file-modal');
    const fileModalTitle = document.getElementById('file-modal-title');
    const fileModalContent = document.getElementById('file-modal-content');
    const fileModalPath = document.getElementById('file-modal-path');
    const fileLoader = document.getElementById('file-loader');
    const editButton = document.getElementById('edit-file-button');
    const saveButton = document.getElementById('save-file-button');
    const cancelEditButton = document.getElementById('cancel-edit-button');
    const editControls = document.getElementById('edit-controls');
    const fileEditWarning = document.getElementById('file-edit-warning');

    // Logs Modal Elements
    const logsModal = document.getElementById('logs-modal');
    const logsModalContent = document.getElementById('logs-modal-content');
    const logsModalServiceName = document.getElementById('logs-modal-service-name');
    const viewLogsButton = document.getElementById('view-logs-button');

    // --- State Variables ---
    let allServicesData = [];
    let currentEditingService = null;
    let currentSortKey = 'unit';
    let currentSortDirection = 'asc';

    // --- Utility Functions ---
    function showToast(message, type = 'info', duration = 4000) {
        const container = document.getElementById('toast-container');
        if (!container) return;

        const toast = document.createElement('div');
        let baseClass = 'custom-toast';
        let typeClass = 'toast-info';
        let icon = 'info';

        switch (type) {
            case 'success': typeClass = 'toast-success'; icon = 'check_circle'; break;
            case 'error': typeClass = 'toast-error'; icon = 'error'; break;
            case 'warning': typeClass = 'toast-warning'; icon = 'warning'; break;
        }

        toast.className = `${baseClass} ${typeClass}`;
        toast.innerHTML = `<i class="material-icons-outlined">${icon}</i><span>${message}</span>`;

        container.appendChild(toast);

        setTimeout(() => {
            toast.classList.add('show');
        }, 10);

        setTimeout(() => {
            toast.classList.remove('show');
            toast.addEventListener('transitionend', () => toast.remove(), { once: true });
        }, duration);
    }

    // --- Modal Controls ---
    function openModal(modalElement) {
        modalElement.classList.remove('hidden');
    }

    function closeModal(modalElement) {
        modalElement.classList.add('hidden');
    }

    statusModal.querySelector('button[onclick*="status-modal"]').addEventListener('click', () => closeModal(statusModal));
    fileModal.querySelector('button[onclick*="file-modal"]').addEventListener('click', () => closeModal(fileModal));
    statusModal.addEventListener('click', (e) => { if (e.target === statusModal) closeModal(statusModal); });
    fileModal.addEventListener('click', (e) => { if (e.target === fileModal) {
        if (editControls.style.display === 'none') {
            closeModal(fileModal);
            resetFileModalToViewMode();
        }
    }});
    logsModal.addEventListener('click', (e) => { if (e.target === logsModal) closeModal(logsModal); });

    // --- API Communication ---
    async function apiRequest(method, url, data = null) {
        try {
            const options = { method: method, headers: {} };
            if (data) { options.headers['Content-Type'] = 'application/json'; options.body = JSON.stringify(data); }
            const response = await fetch(url, options);
            const responseData = await response.json().catch(async () => {
                return { error: `HTTP ${response.status}: ${await response.text().catch(() => response.statusText)}` };
            });

            if (!response.ok) {
                const errorMsg = responseData?.error || responseData?.warning || `Request failed: ${response.status} ${response.statusText}`;
                throw new Error(errorMsg);
            }
            if (responseData.error) throw new Error(responseData.error);
            if (responseData.warning) showToast(responseData.warning, 'warning');

            return responseData;
        } catch (error) {
            console.error(`API Request Failed: ${method} ${url}`, error);
            showToast(error.message, 'error', 6000);
            throw error;
        }
    }

    // --- Service Actions ---
    async function fetchServices() {
        loader.style.display = 'flex';
        serviceTableContainer.style.display = 'none';
        noResults.style.display = 'none';
        serviceListBody.innerHTML = '';

        try {
            const services = await apiRequest('GET', '/api/services');
            allServicesData = services || [];
            applyFilterAndSort();
            updateSortIndicators();
        } catch (error) {
            loader.innerHTML = '<p class="text-red-600">Failed to load services. Check backend logs.</p>';
        } finally {
            loader.style.display = 'none';
        }
    }

    async function performServiceAction(serviceName, action) {
        const buttonQuery = `tr[data-service-name="${serviceName}"] button[data-action="${action}"]`;
        const actionButton = serviceListBody.querySelector(buttonQuery);
        if (actionButton) {
            actionButton.disabled = true;
            actionButton.classList.add('opacity-50', 'cursor-not-allowed');
        }
        showToast(`Performing ${action} on ${serviceName}...`, 'info', 1500);

        try {
            const result = await apiRequest('POST', `/api/services/${serviceName}/${action}`);
            const message = result.success || `${action} successful. ${result.output || ''}`.trim();
            showToast(message, 'success');
            setTimeout(fetchServices, 1000);
        } catch (error) {
            if (actionButton) {
                actionButton.disabled = false;
                actionButton.classList.remove('opacity-50', 'cursor-not-allowed');
            }
        }
    }

    async function showServiceStatus(serviceName) {
        statusModalTitle.textContent = serviceName;
        statusModalContent.textContent = 'Loading status...';
        openModal(statusModal);

        try {
            const result = await apiRequest('GET', `/api/services/${serviceName}/status`);
            statusModalContent.textContent = result.status_output || 'No status output received.';
        } catch (error) {
            statusModalContent.textContent = `Error loading status: ${error.message}`;
        }
    }

    async function showServiceLogs(serviceName) {
        logsModalServiceName.textContent = serviceName;
        logsModalContent.textContent = 'Loading logs...';
        openModal(logsModal);

        try {
            const result = await apiRequest('GET', `/api/services/${serviceName}/logs`);
            logsModalContent.textContent = result.logs_output || 'No logs available.';
        } catch (error) {
            logsModalContent.textContent = `Error loading logs: ${error.message}`;
        }
    }

    // --- File Modal Logic ---
    function resetFileModalToViewMode() {
        fileModalContent.readOnly = true;
        fileModalContent.style.display = 'none';
        editControls.style.display = 'none';
        editButton.style.display = 'none';
        fileLoader.style.display = 'none';
        fileEditWarning.style.display = 'none';
        saveButton.disabled = false;
        cancelEditButton.disabled = false;
        saveButton.classList.remove('opacity-50', 'cursor-not-allowed');
        cancelEditButton.classList.remove('opacity-50', 'cursor-not-allowed');
        fileModalContent.classList.remove('border-m-purple-500', 'ring-1', 'ring-m-purple-300');
        currentEditingService = null;
    }

    async function showServiceFile(serviceName) {
        resetFileModalToViewMode();
        currentEditingService = serviceName;

        fileModalTitle.textContent = serviceName;
        fileModalContent.value = '';
        fileModalPath.textContent = 'Path: Loading...';
        fileLoader.style.display = 'flex';

        openModal(fileModal);

        try {
            const result = await apiRequest('GET', `/api/services/${serviceName}/file`);
            fileModalContent.value = result.file_content || 'No file content received.';
            fileModalPath.textContent = `Path: ${result.file_path || 'N/A'}`;
            fileModalContent.style.display = 'block';
            editButton.style.display = 'inline-flex';
        } catch (error) {
            fileModalContent.value = `Error loading file: ${error.message}`;
            fileModalPath.textContent = 'Path: Error';
            fileModalContent.style.display = 'block';
            editButton.style.display = 'none';
        } finally {
            fileLoader.style.display = 'none';
        }
    }

    // --- UI Rendering ---
    function getStatusClass(status) {
        if (!status) return '';
        status = status.toLowerCase();
        if (status.includes('failed')) return 'status-failed';
        if (status.includes('activating') || status.includes('reloading')) return 'status-activating';
        if (status.includes('active') || status.includes('running')) return 'status-active';
        if (status.includes('inactive') || status.includes('dead')) return 'status-inactive';
        return '';
    }

    function getSubStatusClass(sub) {
        if (!sub) return '';
        sub = sub.toLowerCase();
        if (sub.includes('running')) return 'sub-running';
        if (sub.includes('exited')) return 'sub-exited';
        if (sub.includes('failed')) return 'sub-failed';
        if (sub.includes('dead')) return 'sub-dead';
        return '';
    }

    function getEnabledClass(status) {
        if (!status) return '';
        status = status.toLowerCase();
        if (status === 'enabled' || status === 'enabled-runtime') return 'status-enabled';
        if (status === 'disabled') return 'status-disabled';
        if (status === 'static') return 'status-static';
        if (status === 'masked') return 'status-masked';
        return '';
    }

    function sortData(data, key, direction) {
        if (!key) return data;
        return [...data].sort((a, b) => {
            const valA = a[key]?.toLowerCase() || '';
            const valB = b[key]?.toLowerCase() || '';
            const comparison = valA.localeCompare(valB);
            return direction === 'asc' ? comparison : -comparison;
        });
    }

    function updateSortIndicators() {
        const headers = serviceTableHead.querySelectorAll('th[data-sort-key]');
        headers.forEach(th => {
            const key = th.dataset.sortKey;
            const iconSpan = th.querySelector('.sort-icon');
            if (!iconSpan) return;
            th.classList.remove('sort-active', 'sort-asc', 'sort-desc');
            if (key === currentSortKey) {
                th.classList.add('sort-active');
                th.classList.add(currentSortDirection === 'asc' ? 'sort-asc' : 'sort-desc');
            }
        });
    }

    function renderServiceList(services) {
        serviceListBody.innerHTML = '';

        if (!services || services.length === 0) {
            return;
        }

        const fragment = document.createDocumentFragment();
        services.forEach(service => {
            const row = document.createElement('tr');
            row.dataset.serviceName = service.unit;
            row.classList.add('hover:bg-gray-50/50', 'transition-colors', 'duration-100');

            const enabledClass = getEnabledClass(service.enabled);
            const activeClass = getStatusClass(service.active);
            const subClass = getSubStatusClass(service.sub);

            row.innerHTML = `
                <td class="px-4 py-3 whitespace-nowrap text-sm font-medium text-gray-900">${service.unit}</td>
                <td class="px-4 py-3 whitespace-nowrap text-sm text-gray-500">${service.load}</td>
                <td class="px-4 py-3 whitespace-nowrap text-sm ${activeClass}">${service.active}</td>
                <td class="px-4 py-3 whitespace-nowrap text-sm ${subClass}">${service.sub}</td>
                <td class="px-4 py-3 whitespace-nowrap text-sm ${enabledClass}">${service.enabled}</td>
                <td class="px-4 py-3 text-sm text-gray-500 max-w-xs truncate" title="${service.description}">${service.description}</td>
                <td class="px-4 py-3 whitespace-nowrap text-sm font-medium flex space-x-1 actions-cell">
                    <button title="Start" data-action="start" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-green-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">play_arrow</i></button>
                    <button title="Stop" data-action="stop" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-red-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">stop</i></button>
                    <button title="Restart" data-action="restart" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">refresh</i></button>
                    <button title="Enable" data-action="enable" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-teal-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">power_settings_new</i></button>
                    <button title="Disable" data-action="disable" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-orange-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">remove_circle_outline</i></button>
                    <button title="View/Edit File" data-action="file" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-gray-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">description</i></button>
                    <button title="Status" data-action="status" class="p-1 w-8 h-8 flex items-center justify-center rounded-full transition focus:outline-none focus:ring-2 focus:ring-offset-1 focus:ring-gray-500 disabled:opacity-50 disabled:cursor-not-allowed"><i class="material-icons-outlined text-lg leading-none">info</i></button>
                </td>
            `;
            fragment.appendChild(row);
        });
        serviceListBody.appendChild(fragment);
    }

    function applyFilterAndSort() {
        const searchTerm = searchInput.value.toLowerCase().trim();

        const filteredServices = allServicesData.filter(service => {
            if (!searchTerm) return true;
            return (service.unit?.toLowerCase().includes(searchTerm)) ||
                   (service.description?.toLowerCase().includes(searchTerm)) ||
                   (service.active?.toLowerCase().includes(searchTerm)) ||
                   (service.enabled?.toLowerCase().includes(searchTerm));
        });

        const sortedServices = sortData(filteredServices, currentSortKey, currentSortDirection);

        renderServiceList(sortedServices);

        if (sortedServices.length > 0) {
            noResults.style.display = 'none';
            serviceTableContainer.style.display = 'block';
        } else {
            noResults.style.display = 'block';
            serviceTableContainer.style.display = 'none';
        }
    }

    // --- Event Delegation ---
    serviceListBody.addEventListener('click', (event) => {
        const button = event.target.closest('button[data-action]');
        if (button) { handleActionClick(button); }
    });

    serviceTableHead.addEventListener('click', (event) => {
        const header = event.target.closest('th[data-sort-key]');
        if (header) { handleSortClick(header); }
    });

    function handleActionClick(button) {
        const action = button.dataset.action;
        const serviceName = button.closest('tr')?.dataset.serviceName;
        if (!serviceName || !action) return;
        switch (action) {
            case 'start': case 'stop': case 'restart': case 'enable': case 'disable':
                performServiceAction(serviceName, action); break;
            case 'status': showServiceStatus(serviceName); break;
            case 'file': showServiceFile(serviceName); break;
        }
    }

    function handleSortClick(header) {
        const newSortKey = header.dataset.sortKey;
        if (newSortKey === currentSortKey) {
            currentSortDirection = currentSortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            currentSortKey = newSortKey;
            currentSortDirection = 'asc';
        }
        updateSortIndicators();
        applyFilterAndSort();
    }

    // --- Global Event Listeners ---
    searchInput.addEventListener('input', applyFilterAndSort);
    refreshButton.addEventListener('click', fetchServices);
    daemonReloadButton.addEventListener('click', () => { performServiceAction('daemon', 'daemon-reload'); });
    viewLogsButton?.addEventListener('click', () => {
        const serviceName = statusModalTitle.textContent;
        if (serviceName) showServiceLogs(serviceName);
    });

    // --- File Modal Edit/Save/Cancel Listeners ---
    editButton.addEventListener('click', () => {
        fileModalContent.readOnly = false;
        editControls.style.display = 'flex';
        editButton.style.display = 'none';
        fileEditWarning.style.display = 'block';
        fileModalContent.focus();
        fileModalContent.classList.add('border-m-purple-500', 'ring-1', 'ring-m-purple-300');
        showToast('Editing enabled. Be careful!', 'warning');
    });

    cancelEditButton.addEventListener('click', () => {
        if (currentEditingService) {
            showToast('Changes cancelled. Reloading file...', 'info', 1500);
            showServiceFile(currentEditingService);
        } else {
            resetFileModalToViewMode();
        }
    });

    saveButton.addEventListener('click', async () => {
        if (!currentEditingService) { showToast('Error: No service context for saving.', 'error'); return; }
        const newContent = fileModalContent.value;

        if (!confirm(`ARE YOU SURE?\n\nSaving changes to '${currentEditingService}' can break your system if incorrect.\n\nProceed with saving?`)) {
            return;
        }

        showToast(`Saving file for ${currentEditingService}...`, 'info');
        saveButton.disabled = true;
        cancelEditButton.disabled = true;
        saveButton.classList.add('opacity-50', 'cursor-not-allowed');
        cancelEditButton.classList.add('opacity-50', 'cursor-not-allowed');
        fileModalContent.readOnly = true;

        try {
            const result = await apiRequest('POST', `/api/services/${currentEditingService}/file`, { content: newContent });
            const message = result.success || `File saved. ${result.output || ''}`.trim();
            showToast(message, 'success');
            closeModal(fileModal);
            resetFileModalToViewMode();
        } catch (error) {
            saveButton.disabled = false;
            cancelEditButton.disabled = false;
            saveButton.classList.remove('opacity-50', 'cursor-not-allowed');
            cancelEditButton.classList.remove('opacity-50', 'cursor-not-allowed');
            fileModalContent.readOnly = false;
            fileModalContent.focus();
        }
    });

    // --- Initial Load ---
    fetchServices();
});
