package simplecompute

// Uses Odin's DirectX binding. For Agility SDK features, additonal bindings are necessary.
import win "core:sys/windows"
import dx12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"

NUM_ELEMS :: 1024 * 1024
BUFFER_SIZE :: NUM_ELEMS * size_of(u32)
THREAD_GROUP_SIZE_X :: 64
THREAD_GROUP_COUNT_X :: (NUM_ELEMS + THREAD_GROUP_SIZE_X - 1) / THREAD_GROUP_SIZE_X

DEFAULT_HEAP_PROPS :: dx12.HEAP_PROPERTIES {
	Type                 = .DEFAULT,
	CPUPageProperty      = .UNKNOWN,
	MemoryPoolPreference = .UNKNOWN,
	CreationNodeMask     = 0 << 1,
	VisibleNodeMask      = 0 << 1,
}

DEFAULT_BUFFER_RESOURCE_DESC :: dx12.RESOURCE_DESC {
	Dimension = .BUFFER,
	Width = 1,
	Height = 1,
	DepthOrArraySize = 1,
	MipLevels = 1,
	Format = .UNKNOWN,
	SampleDesc = dxgi.SAMPLE_DESC{Count = 1, Quality = 0},
	Layout = .ROW_MAJOR,
	Flags = {},
}

create_committed_resource_with_heap_type :: proc(
	device : ^dx12.IDevice,
	resource_desc : dx12.RESOURCE_DESC,
	heap_type : dx12.HEAP_TYPE,
	heap_flags : dx12.HEAP_FLAGS = {},
) -> (
	resource : ^dx12.IResource,
) {
	init_state : dx12.RESOURCE_STATES = dx12.RESOURCE_STATE_COMMON
	heap_prop := DEFAULT_HEAP_PROPS
	heap_prop.Type = heap_type

	desc := resource_desc

	#partial switch heap_type {
	case .UPLOAD:
		init_state = dx12.RESOURCE_STATE_GENERIC_READ
	case .READBACK:
		init_state = {.COPY_DEST}
	// In this simple example the default heap only contains our UAV 
	// so could skip a resource transistion barrier by using...
	// case .DEFAULT:
	//	init_state = { .}
	//  	init_state = { .UNORDERED_ACCESS }
	}

	device->CreateCommittedResource(
		&heap_prop,
		heap_flags,
		&desc,
		init_state,
		nil,
		dx12.IResource_UUID,
		(^rawptr)(&resource),
	)
	resource->SetName(raw_data(win.utf8_to_utf16(fmt.tprint(heap_type))))

	return resource
}

resource_barrier :: proc(
	cmd_list : ^dx12.IGraphicsCommandList,
	resource : ^dx12.IResource,
	before : dx12.RESOURCE_STATES,
	after : dx12.RESOURCE_STATES,
	flags : dx12.RESOURCE_BARRIER_FLAGS = {},
) {
	barrier_desc : dx12.RESOURCE_BARRIER
	barrier_desc.Type = .TRANSITION
	barrier_desc.Flags = flags
	barrier_desc.Transition.pResource = resource
	barrier_desc.Transition.Subresource = dx12.RESOURCE_BARRIER_ALL_SUBRESOURCES
	barrier_desc.Transition.StateBefore = before
	barrier_desc.Transition.StateAfter = after

	cmd_list->ResourceBarrier(1, &barrier_desc)
}

execute_wait :: proc(
	cmd_queue : ^dx12.ICommandQueue,
	cmd_list : ^dx12.IGraphicsCommandList,
	fence : ^dx12.IFence,
	fence_event : dx12.HANDLE,
	fence_value : ^u64,
) {
	hr : dx12.HRESULT
	hr = cmd_list->Close()
	check(hr, "Failed to clost Command List")

	cmd_lists := [?]^dx12.ICommandList{cmd_list}
	cmd_queue->ExecuteCommandLists(len(cmd_lists), &cmd_lists[0])

	curr_fence_value := fence_value^
	hr = cmd_queue->Signal(fence, curr_fence_value)
	check(hr)
	fence_value^ += 1

	for fence->GetCompletedValue() < curr_fence_value {
		hr = fence->SetEventOnCompletion(curr_fence_value, fence_event)
		check(hr)
		win.WaitForSingleObject(fence_event, win.INFINITE)
	}
}

// minimal adapter identification
get_first_hw_adapter :: proc(
	factory : ^dxgi.IFactory7,
) -> (
	adapter : ^dxgi.IAdapter1,
	adapter_desc : dxgi.ADAPTER_DESC1,
) {
	for i : u32 = 0; factory->EnumAdapters1(i, &adapter) != dxgi.ERROR_NOT_FOUND; i += 1 {
		adapter->GetDesc1(&adapter_desc)

		// skip non-hardware adapters
		if dxgi.ADAPTER_FLAG.SOFTWARE in adapter_desc.Flags {continue}

		// if using a UTF codepage need to convert description from UTF16
		log.infof(
			"Found HW adapter: %s (video memory=%dMB)",
			adapter_desc.Description,
			adapter_desc.DedicatedVideoMemory / 1024 / 1024,
		)
		return adapter, adapter_desc
	}

	return nil, {}
}

main :: proc() {
	context.logger = log.create_console_logger(.Info, {})

	hr : dx12.HRESULT

	when ODIN_DEBUG {
		// use a tracking allocator when in DEBUG
		default_allocator := context.allocator
		tracking_allocator : mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, default_allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)
	}

	dxgi_factory_flags : dxgi.CREATE_FACTORY = {}
	when ODIN_DEBUG {
		debug_ctrl : ^dx12.IDebug
		check(dx12.GetDebugInterface(dx12.IDebug_UUID, (^rawptr)(&debug_ctrl)))
		defer debug_ctrl->Release()

		debug_ctrl.EnableDebugLayer(debug_ctrl)
		dxgi_factory_flags = {dxgi.CREATE_FACTORY.DEBUG}

		dxgi_debug : ^dxgi.IDebug1
		check(dxgi.DXGIGetDebugInterface1(0, dxgi.IDebug1_UUID, (^rawptr)(&dxgi_debug)))
		defer dxgi_debug->Release()
		// Did we catch'em all?
		defer dxgi_debug->ReportLiveObjects(dxgi.DEBUG_ALL, .SUMMARY)
	}

	factory : ^dxgi.IFactory7
	dxgi.CreateDXGIFactory2(dxgi_factory_flags, dxgi.IFactory7_UUID, (^rawptr)(&factory))
	defer factory->Release()

	adapter, adapter_desc := get_first_hw_adapter(factory)
	defer adapter->Release()

	device : ^dx12.IDevice
	hr = dx12.CreateDevice(adapter, ._12_0, dx12.IDevice1_UUID, (^rawptr)(&device))
	check(hr, "Failed to create device.")
	defer device->Release()

	queue_desc : dx12.COMMAND_QUEUE_DESC
	queue_desc.Type = .DIRECT

	cmd_queue : ^dx12.ICommandQueue
	hr = device->CreateCommandQueue(&queue_desc, dx12.ICommandQueue_UUID, (^rawptr)(&cmd_queue))
	check(hr, "Failed to create command allocator.")
	defer cmd_queue->Release()

	cmd_alloc : ^dx12.ICommandAllocator
	hr = device->CreateCommandAllocator(queue_desc.Type, dx12.ICommandAllocator_UUID, (^rawptr)(&cmd_alloc))
	check(hr, "Failed to create command allocator.")
	cmd_alloc->SetName(win.L("CmdAlloc"))
	defer cmd_alloc->Release()

	cmd_list : ^dx12.IGraphicsCommandList6
	hr =
	device->CreateCommandList(
		queue_desc.NodeMask,
		queue_desc.Type,
		cmd_alloc,
		nil,
		dx12.IGraphicsCommandList6_UUID,
		(^rawptr)(&cmd_list),
	)
	check(hr, "Failed to create command list. ")

	cmd_lists : []^dx12.ICommandList

	fence : ^dx12.IFence
	device->CreateFence(0, nil, dx12.IFence_UUID, (^rawptr)(&fence))
	fence_event : dx12.HANDLE = win.CreateEventW(nil, false, false, nil)
	defer fence->Release()
	defer win.CloseHandle(fence_event)
	fence_value : u64

	log.info("Created dx1212 Objects")

	// Load the shader file.
	shader, shader_ok := os.read_entire_file_from_filename("simplecompute.cso")
	if !shader_ok {panic("Failed to load shader.")}

	// Extract the root signature from the hlsl.
	rs : ^dx12.IRootSignature
	hr = device->CreateRootSignature(0, raw_data(shader), len(shader), dx12.IRootSignature_UUID, (^rawptr)(&rs))
	check(hr, "Failed to create root signature")
	rs->SetName(win.L("ComputeRS"))
	defer rs->Release()

	// Create the compute pipeline.
	ps : ^dx12.IPipelineState
	pipeline_desc : dx12.COMPUTE_PIPELINE_STATE_DESC = {}
	pipeline_desc.pRootSignature = nil
	pipeline_desc.CS = {
		pShaderBytecode = raw_data(shader),
		BytecodeLength  = len(shader),
	}
	hr = device->CreateComputePipelineState(&pipeline_desc, dx12.IPipelineState_UUID, (^rawptr)(&ps))
	check(hr, "Failed to create Compute Pipeline State")
	defer ps->Release()

	log.info("Created Shader objects")

	buffer_desc := DEFAULT_BUFFER_RESOURCE_DESC
	buffer_desc.Width = BUFFER_SIZE

	// Create upload buffer resource.
	upload_buffer := create_committed_resource_with_heap_type(device, buffer_desc, .UPLOAD)
	defer upload_buffer->Release()

	// Create readback buffer resource.
	readback_buffer := create_committed_resource_with_heap_type(device, buffer_desc, .READBACK)
	defer readback_buffer->Release()

	// Create the compute resource.
	buffer_desc.Flags = {.ALLOW_UNORDERED_ACCESS}
	compute_buffer := create_committed_resource_with_heap_type(device, buffer_desc, .DEFAULT)
	defer compute_buffer->Release()

	// Create some example input data to multiply in the compute shader
	input_data := make([]u32, NUM_ELEMS)
	for &elem, i in input_data {
		elem = u32(i)
	}
	defer delete(input_data)

	// Map upload buffer.
	mapped_data : rawptr
	hr = upload_buffer->Map(0, nil, &mapped_data)
	check(hr, "Failed to map Upload Buffer")
	// mem.copy( mapped_data, &input_data[0], BUFFER_SIZE )
	mem.copy(mapped_data, &input_data[0], BUFFER_SIZE)
	upload_buffer->Unmap(0, nil)

	/*
	// If using descriptor heaps in root signature...

	heap_desc : dx12.DESCRIPTOR_HEAP_DESC
	heap_desc.Type = .CBV_SRV_UAV
	heap_desc.NumDescriptors = 1
	heap_desc.Flags = { .SHADER_VISIBLE }

	descriptor_heap : ^dx12.IDescriptorHeap
	hr = device->CreateDescriptorHeap( &heap_desc, dx12.IDescriptorHeap_UUID, (^rawptr)(&descriptor_heap) )
	hrchk( hr, "Failed to create descriptor heap" )
	defer descriptor_heap->Release()

	uav_desc : dx12.UNORDERED_ACCESS_VIEW_DESC
	uav_desc.Format = .UNKNOWN
	uav_desc.ViewDimension = .BUFFER
	uav_desc.Buffer.NumElements = NUM_ELEMS
	uav_desc.Buffer.StructureByteStride = size_of(u32)

	cpu_handle : dx12.CPU_DESCRIPTOR_HANDLE
	descriptor_heap->GetCPUDescriptorHandleForHeapStart( &cpu_handle )
	device->CreateUnorderedAccessView( compute_buffer, nil, &uav_desc, cpu_handle )
	*/

	// Make sure the compute resource is in a copy-to ready state but
	// may not needed if creating the resource in UNORDERED_ACCESS state.
	resource_barrier(cmd_list, compute_buffer, dx12.RESOURCE_STATE_COMMON, {.COPY_DEST})

	// Copy the whole buffer.
	cmd_list->CopyBufferRegion(compute_buffer, 0, upload_buffer, 0, BUFFER_SIZE)

	// Transistion to a compute ready state.
	resource_barrier(cmd_list, compute_buffer, {.COPY_DEST}, {.UNORDERED_ACCESS})

	// Execute the copy and barriers.
	execute_wait(cmd_queue, cmd_list, fence, fence_event, &fence_value)

	check(cmd_alloc->Reset())
	check(cmd_list->Reset(cmd_alloc, nil))

	// Compute pipeline.
	cmd_list->SetComputeRootSignature(rs)
	cmd_list->SetPipelineState(ps)
	// If using descriptor heaps...
	// cmd_list->SetDescriptorHeaps(1, &descriptor_heap) // not needed because we have a root level UAV
	cmd_list->SetComputeRootUnorderedAccessView(0, compute_buffer->GetGPUVirtualAddress())

	// Dispatch the shader.
	cmd_list->Dispatch(THREAD_GROUP_COUNT_X, 1, 1)
	execute_wait(cmd_queue, cmd_list, fence, fence_event, &fence_value)

	check(cmd_alloc->Reset())
	check(cmd_list->Reset(cmd_alloc, nil))

	// Transistion from compute state to copy-from state.
	resource_barrier(cmd_list, compute_buffer, {.UNORDERED_ACCESS}, {.COPY_SOURCE})

	cmd_list->CopyResource(readback_buffer, compute_buffer)

	// Execute the copy back to the readback buffer.
	execute_wait(cmd_queue, cmd_list, fence, fence_event, &fence_value)

	// Map the readback buffer.
	result_data : rawptr
	hr = readback_buffer->Map(0, nil, &result_data)
	check(hr)

	output_data := make([]u32, NUM_ELEMS)
	defer delete(output_data)
	mem.copy(&output_data[0], result_data, BUFFER_SIZE)
	readback_buffer->Unmap(0, nil)

	// Print some results.
	log.infof("Output: %v...%v", output_data[:10], output_data[NUM_ELEMS - 10:])
}

check :: proc {
	check_hr,
}

check_hr :: proc(hr : dx12.HRESULT, message : string = "", loc := #caller_location) {
	if (hr < 0) {
		// panic at the actual location with correct error code.
		// fmt.panicf("%v | %s with error code: %#x\n", loc, message, u32(hr) )

		log.errorf("DirectX error at %v: %s | HRESULT 0x%08x\n", loc, message, u32(hr))
		panic("DirectX call failed")
	}
	// todo! - convert HRESULT to the correct using formatmessage 
	// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-formatmessage
	// and provide link to online docs
}
