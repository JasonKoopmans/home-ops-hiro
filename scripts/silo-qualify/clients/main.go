// Scoped-policy replay with real S3 client libraries against a scratch Silo.
// minio-go v7.0.93 is what Thanos v0.42.4 links; aws-sdk-go-v2 (default CRC32 request checksums) stands in for Loki.
// Prints one "PASS|FAIL <name>: detail" line per check; exit code 1 if any FAIL.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awscfg "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/minio/minio-go/v7"
	mcreds "github.com/minio/minio-go/v7/pkg/credentials"
)

var failed bool

func rep(ok bool, name, detail string) {
	s := "PASS"
	if !ok {
		s, failed = "FAIL", true
	}
	fmt.Printf("%s %s: %s\n", s, name, detail)
}

func blob(n int) []byte   { b := make([]byte, n); rand.Read(b); return b }
func sum(b []byte) string { h := sha256.Sum256(b); return fmt.Sprintf("%x", h[:6]) }
func env(k string) string { return os.Getenv(k) }

func main() {
	ctx := context.Background()
	ep := env("ENDPOINT") // host:port
	thanosBucket, lokiBucket := "observability-thanos", "observability-loki"

	// ---- (a) minio-go as the Thanos scoped user
	mc, err := minio.New(ep, &minio.Options{Creds: mcreds.NewStaticV4(env("THANOS_AK"), env("THANOS_SK"), ""), Secure: false})
	if err != nil {
		panic(err)
	}
	small, big := blob(1<<20), blob(40<<20)
	_, err = mc.PutObject(ctx, thanosBucket, "t/small", bytes.NewReader(small), int64(len(small)), minio.PutObjectOptions{})
	rep(err == nil, "minio-go thanos PutObject 1MiB", fmt.Sprint(err))
	_, err = mc.PutObject(ctx, thanosBucket, "t/big", bytes.NewReader(big), int64(len(big)), minio.PutObjectOptions{PartSize: 16 << 20})
	rep(err == nil, "minio-go thanos multipart Put 40MiB (3 parts)", fmt.Sprint(err))
	st, err := mc.StatObject(ctx, thanosBucket, "t/big", minio.StatObjectOptions{})
	rep(err == nil && st.Size == int64(len(big)), "minio-go thanos StatObject", fmt.Sprintf("size=%d etag=%s err=%v", st.Size, st.ETag, err))
	o, err := mc.GetObject(ctx, thanosBucket, "t/big", minio.GetObjectOptions{})
	var got []byte
	if err == nil {
		got, err = io.ReadAll(o)
	}
	rep(err == nil && sum(got) == sum(big), "minio-go thanos GetObject sha256", sum(got)+" vs "+sum(big))
	ro := minio.GetObjectOptions{}
	ro.SetRange(100, 1123)
	o, _ = mc.GetObject(ctx, thanosBucket, "t/big", ro)
	part, err := io.ReadAll(o)
	rep(err == nil && len(part) == 1024 && bytes.Equal(part, big[100:1124]), "minio-go thanos ranged Get", fmt.Sprintf("len=%d err=%v", len(part), err))
	n := 0
	for r := range mc.ListObjects(ctx, thanosBucket, minio.ListObjectsOptions{Prefix: "t/", Recursive: true}) {
		if r.Err == nil {
			n++
		}
	}
	rep(n == 2, "minio-go thanos ListObjects", fmt.Sprintf("n=%d", n))
	vi, err := mc.GetBucketVersioning(ctx, thanosBucket)
	rep(err != nil || vi.Status != "Enabled", "bucket versioning state (expect Suspended/unset)", fmt.Sprintf("%q err=%v", vi.Status, err))
	err = mc.RemoveObject(ctx, thanosBucket, "t/small", minio.RemoveObjectOptions{})
	rep(err == nil, "minio-go thanos plain RemoveObject (versioning suspended)", fmt.Sprint(err))
	_, err = mc.StatObject(ctx, thanosBucket, "t/small", minio.StatObjectOptions{})
	rep(err != nil && minio.ToErrorResponse(err).Code == "NoSuchKey", "deleted object now NoSuchKey", fmt.Sprint(err))
	for e := range mc.RemoveObjects(ctx, thanosBucket, objCh("t/big"), minio.RemoveObjectsOptions{}) {
		rep(false, "minio-go RemoveObjects (batch)", fmt.Sprint(e))
	}
	_, err = mc.StatObject(ctx, thanosBucket, "t/big", minio.StatObjectOptions{})
	rep(err != nil, "minio-go thanos batch delete (DeleteObjects) removed object", fmt.Sprint(err))
	// scope: thanos user must not touch the loki bucket
	_, err = mc.PutObject(ctx, lokiBucket, "x", bytes.NewReader(small[:10]), 10, minio.PutObjectOptions{})
	rep(err != nil && minio.ToErrorResponse(err).Code == "AccessDenied", "thanos user denied on loki bucket", fmt.Sprint(err))

	// ---- (b) aws-sdk-go-v2 as the Loki scoped user (default request checksums = CRC32)
	cfg, err := awscfg.LoadDefaultConfig(ctx, awscfg.WithRegion("us-east-1"),
		awscfg.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(env("LOKI_AK"), env("LOKI_SK"), "")))
	if err != nil {
		panic(err)
	}
	cl := s3.NewFromConfig(cfg, func(o *s3.Options) { o.BaseEndpoint = aws.String("http://" + ep); o.UsePathStyle = true })
	_, err = cl.PutObject(ctx, &s3.PutObjectInput{Bucket: &lokiBucket, Key: aws.String("l/small"), Body: bytes.NewReader(small)})
	rep(err == nil, "aws-sdk-go-v2 loki PutObject (default CRC32)", fmt.Sprint(err))
	up := manager.NewUploader(cl, func(u *manager.Uploader) { u.PartSize = 8 << 20 })
	_, err = up.Upload(ctx, &s3.PutObjectInput{Bucket: &lokiBucket, Key: aws.String("l/big"), Body: bytes.NewReader(big)})
	rep(err == nil, "aws-sdk-go-v2 loki multipart upload 40MiB", fmt.Sprint(err))
	g, err := cl.GetObject(ctx, &s3.GetObjectInput{Bucket: &lokiBucket, Key: aws.String("l/big")})
	got = nil
	if err == nil {
		got, err = io.ReadAll(g.Body)
	}
	rep(err == nil && sum(got) == sum(big), "aws-sdk-go-v2 GetObject sha256", sum(got))
	lo, err := cl.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: &lokiBucket, Prefix: aws.String("l/")})
	rep(err == nil && len(lo.Contents) == 2, "aws-sdk-go-v2 ListObjectsV2", fmt.Sprintf("err=%v", err))
	_, err = cl.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &lokiBucket, Key: aws.String("l/small")})
	rep(err == nil, "aws-sdk-go-v2 plain DeleteObject (no If-Match)", fmt.Sprint(err))
	do, err := cl.DeleteObjects(ctx, &s3.DeleteObjectsInput{Bucket: &lokiBucket, Delete: &s3types.Delete{Objects: []s3types.ObjectIdentifier{{Key: aws.String("l/big")}}}})
	rep(err == nil && len(do.Errors) == 0, "aws-sdk-go-v2 DeleteObjects batch", fmt.Sprintf("err=%v", err))
	_, err = cl.PutObject(ctx, &s3.PutObjectInput{Bucket: &thanosBucket, Key: aws.String("x"), Body: strings.NewReader("x")})
	rep(err != nil, "loki user denied on thanos bucket", fmt.Sprint(err))

	// ---- (c) RA user: List/GetBucketLocation/Get/Put only
	ra, _ := minio.New(ep, &minio.Options{Creds: mcreds.NewStaticV4(env("RA_AK"), env("RA_SK"), ""), Secure: false})
	rb := "recordings"
	data := blob(2 << 20)
	_, err = ra.PutObject(ctx, rb, "a/b.bin", bytes.NewReader(data), int64(len(data)), minio.PutObjectOptions{ContentType: "video/mp4"})
	rep(err == nil, "RA user PutObject", fmt.Sprint(err))
	_, err = ra.StatObject(ctx, rb, "a/b.bin", minio.StatObjectOptions{})
	rep(err == nil, "RA user StatObject (HEAD needs s3:GetObject)", fmt.Sprint(err))
	err = ra.RemoveObject(ctx, rb, "a/b.bin", minio.RemoveObjectOptions{})
	rep(err != nil && minio.ToErrorResponse(err).Code == "AccessDenied", "RA user DeleteObject denied", fmt.Sprint(err))
	_, err = ra.PutObject(ctx, thanosBucket, "x", bytes.NewReader(data[:10]), 10, minio.PutObjectOptions{})
	rep(err != nil && minio.ToErrorResponse(err).Code == "AccessDenied", "RA user denied on other bucket", fmt.Sprint(err))
	_, err = ra.GetBucketLocation(ctx, rb)
	rep(err == nil, "RA user GetBucketLocation", fmt.Sprint(err))
	_, err = ra.PutObject(ctx, rb, "a/multi.bin", bytes.NewReader(big), int64(len(big)), minio.PutObjectOptions{PartSize: 16 << 20})
	rep(err == nil, "RA user multipart Put 40MiB (needs only PutObject)", fmt.Sprint(err))
	_, err = ra.ListBuckets(ctx)
	fmt.Printf("INFO RA user ListBuckets: %v (info only)\n", err)

	// ---- (d) presigned GET: Range -> 206, expiry rejected, CORS headers
	u, err := ra.PresignedGetObject(ctx, rb, "a/b.bin", 3600*time.Second, nil)
	rep(err == nil, "presign GET (TTL 3600s)", "")
	rq, _ := http.NewRequest("GET", u.String(), nil)
	rq.Header.Set("Range", "bytes=0-1023")
	rq.Header.Set("Origin", "https://app.example.test")
	rs, err := http.DefaultClient.Do(rq)
	if err == nil {
		b, _ := io.ReadAll(rs.Body)
		rep(rs.StatusCode == 206 && len(b) == 1024 && bytes.Equal(b, data[:1024]), "presigned Range bytes=0-1023", fmt.Sprintf("status=%d len=%d content-range=%q", rs.StatusCode, len(b), rs.Header.Get("Content-Range")))
		fmt.Printf("INFO CORS(Origin https://app.example.test): ACAO=%q ACEH=%q Vary=%q\n", rs.Header.Get("Access-Control-Allow-Origin"), rs.Header.Get("Access-Control-Expose-Headers"), rs.Header.Get("Vary"))
	} else {
		rep(false, "presigned Range", err.Error())
	}
	pre, _ := http.NewRequest("OPTIONS", u.String(), nil)
	pre.Header.Set("Origin", "https://app.example.test")
	pre.Header.Set("Access-Control-Request-Method", "GET")
	pre.Header.Set("Access-Control-Request-Headers", "range")
	if rs, err := http.DefaultClient.Do(pre); err == nil {
		fmt.Printf("INFO CORS preflight: status=%d ACAO=%q ACAH=%q ACAM=%q\n", rs.StatusCode, rs.Header.Get("Access-Control-Allow-Origin"), rs.Header.Get("Access-Control-Allow-Headers"), rs.Header.Get("Access-Control-Allow-Methods"))
	}
	u2, _ := ra.PresignedGetObject(ctx, rb, "a/b.bin", 1*time.Second, nil)
	time.Sleep(3 * time.Second)
	rs, err = http.Get(u2.String())
	if err == nil {
		b, _ := io.ReadAll(rs.Body)
		rep(rs.StatusCode == 403 && (strings.Contains(string(b), "ExpiredToken") || strings.Contains(string(b), "expired")), "expired presigned URL rejected", fmt.Sprintf("status=%d body=%.120s", rs.StatusCode, strings.ReplaceAll(string(b), "\n", " ")))
	}
	// ---- (e) mc rm is exercised by the shell wrapper
	if failed {
		os.Exit(1)
	}
}

func objCh(keys ...string) <-chan minio.ObjectInfo {
	c := make(chan minio.ObjectInfo, len(keys))
	for _, k := range keys {
		c <- minio.ObjectInfo{Key: k}
	}
	close(c)
	return c
}
