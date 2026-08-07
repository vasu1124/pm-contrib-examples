package boincrpc

import (
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const (
	BatchStateInProgress = 1
	BatchStateCompleted  = 2
	BatchStateAborted    = 3
)

type Client struct {
	projectURL    string
	authenticator string
	httpClient    *http.Client
}

func NewClient(projectURL, authenticator string) *Client {
	return &Client{
		projectURL:    strings.TrimSuffix(projectURL, "/"),
		authenticator: authenticator,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// XML structures
type CreateBatchRequest struct {
	XMLName       xml.Name `xml:"create_batch"`
	Authenticator string   `xml:"authenticator"`
	AppName       string   `xml:"app_name"`
	BatchName     string   `xml:"batch_name"`
	ExpireTime    int      `xml:"expire_time"`
}

type CreateBatchResponse struct {
	XMLName xml.Name `xml:"create_batch"`
	BatchID int64    `xml:"batch_id"`
}

type JobSpec struct {
	Command       string
	FlopsEstimate string
	MemoryBound   string
	DiskBound     string
}

type job struct {
	CommandLine    string `xml:"command_line"`
	RscFpopsEst    string `xml:"rsc_fpops_est"`
	RscMemoryBound string `xml:"rsc_memory_bound"`
	RscDiskBound   string `xml:"rsc_disk_bound"`
}

type batch struct {
	BatchID int64 `xml:"batch_id"`
	Jobs    []job `xml:"job"`
}

type SubmitBatchRequest struct {
	XMLName       xml.Name `xml:"submit_batch"`
	Authenticator string   `xml:"authenticator"`
	Batch         batch    `xml:"batch"`
}

type SubmitBatchResponse struct {
	XMLName xml.Name `xml:"submit_batch"`
	BatchID int64    `xml:"batch_id"`
}

type QueryBatchesRequest struct {
	XMLName       xml.Name `xml:"query_batches"`
	Authenticator string   `xml:"authenticator"`
	BatchID       int64    `xml:"batch_id"`
}

type BatchStatus struct {
	ID            int64   `xml:"id"`
	Name          string  `xml:"name"`
	State         int     `xml:"state"`
	NJobs         int     `xml:"njobs"`
	NErrorJobs    int     `xml:"nerror_jobs"`
	CompletionPct float64 `xml:"completion_pct"`
}

type QueryBatchesResponse struct {
	XMLName xml.Name     `xml:"query_batches"`
	Batch   *BatchStatus `xml:"batch"`
}

type AbortBatchRequest struct {
	XMLName       xml.Name `xml:"abort_batch"`
	Authenticator string   `xml:"authenticator"`
	BatchID       int64    `xml:"batch_id"`
}

type AbortBatchResponse struct {
	XMLName xml.Name `xml:"abort_batch"`
	Success *string  `xml:"success"`
}

type RetireBatchRequest struct {
	XMLName       xml.Name `xml:"retire_batch"`
	Authenticator string   `xml:"authenticator"`
	BatchID       int64    `xml:"batch_id"`
}

type RetireBatchResponse struct {
	XMLName xml.Name `xml:"retire_batch"`
	Success *string  `xml:"success"`
}

type ErrorResponse struct {
	XMLName  xml.Name `xml:"error"`
	ErrorNum int      `xml:"error_num"`
	ErrorMsg string   `xml:"error_msg"`
}

func (c *Client) doRequest(ctx context.Context, xmlBody interface{}) ([]byte, error) {
	reqBody, err := xml.Marshal(xmlBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	url := fmt.Sprintf("%s/submit_rpc_handler.php", c.projectURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/xml")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code %d: %s", resp.StatusCode, string(body))
	}

	// Check for <error> in response
	var errResp ErrorResponse
	if err := xml.Unmarshal(body, &errResp); err == nil && errResp.ErrorNum != 0 {
		return nil, fmt.Errorf("boinc error %d: %s", errResp.ErrorNum, errResp.ErrorMsg)
	}

	return body, nil
}

func (c *Client) CreateBatch(ctx context.Context, batchName string) (int64, error) {
	req := CreateBatchRequest{
		Authenticator: c.authenticator,
		AppName:       "boinc2docker",
		BatchName:     batchName,
		ExpireTime:    0,
	}

	body, err := c.doRequest(ctx, req)
	if err != nil {
		return 0, fmt.Errorf("CreateBatch failed: %w", err)
	}

	var resp CreateBatchResponse
	if err := xml.Unmarshal(body, &resp); err != nil {
		return 0, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	return resp.BatchID, nil
}

func (c *Client) SubmitBatch(ctx context.Context, batchID int64, jobs []JobSpec) error {
	var boincJobs []job
	for _, j := range jobs {
		boincJobs = append(boincJobs, job{
			CommandLine:    j.Command,
			RscFpopsEst:    j.FlopsEstimate,
			RscMemoryBound: j.MemoryBound,
			RscDiskBound:   j.DiskBound,
		})
	}

	req := SubmitBatchRequest{
		Authenticator: c.authenticator,
		Batch: batch{
			BatchID: batchID,
			Jobs:    boincJobs,
		},
	}

	_, err := c.doRequest(ctx, req)
	if err != nil {
		return fmt.Errorf("SubmitBatch failed: %w", err)
	}

	return nil
}

func (c *Client) QueryBatch(ctx context.Context, batchID int64) (*BatchStatus, error) {
	req := QueryBatchesRequest{
		Authenticator: c.authenticator,
		BatchID:       batchID,
	}

	body, err := c.doRequest(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("QueryBatch failed: %w", err)
	}

	var resp QueryBatchesResponse
	if err := xml.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	if resp.Batch == nil {
		return nil, fmt.Errorf("batch not found in response")
	}

	return resp.Batch, nil
}

func (c *Client) AbortBatch(ctx context.Context, batchID int64) error {
	req := AbortBatchRequest{
		Authenticator: c.authenticator,
		BatchID:       batchID,
	}

	_, err := c.doRequest(ctx, req)
	if err != nil {
		return fmt.Errorf("AbortBatch failed: %w", err)
	}

	return nil
}

func (c *Client) RetireBatch(ctx context.Context, batchID int64) error {
	req := RetireBatchRequest{
		Authenticator: c.authenticator,
		BatchID:       batchID,
	}

	_, err := c.doRequest(ctx, req)
	if err != nil {
		return fmt.Errorf("RetireBatch failed: %w", err)
	}

	return nil
}
